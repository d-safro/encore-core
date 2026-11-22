import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/settings.dart';
import 'audiobooks.dart';
import 'song_download.dart';

/// Audiobooks kept on this device for listening offline: a book's files (as Audiobookshelf has them) in
/// `<support>/audiobooks/<book>/`, downloaded with [resumableDownload] (a broken download carries on from where
/// it stopped). What's kept is listed in the pref `bookDownloads`, with what's needed to play it without the
/// server: the title, author, chapters and where each file begins in the book.

const _system = MethodChannel('encore/system');

class KeptBook {
  const KeptBook(this.book, this.tracks);
  final Book book; // its cover is the server's address (shown when online; a placeholder otherwise)
  final List<BookTrack> tracks; // url: the file on this device

  Map<String, dynamic> toJson() => {
    'id': book.id,
    'title': book.title,
    'author': book.author,
    'narrator': book.narrator,
    'duration': book.duration,
    'cover': book.cover,
    'chapters': [for (final c in book.chapters) {'start': c.start, 'end': c.end, 'title': c.title}],
    'tracks': [for (final t in tracks) {'start': t.start, 'duration': t.duration, 'file': t.url, 'mime': t.mime}],
  };

  static KeptBook? fromJson(Object? j) {
    if (j is! Map || j['id'] == null) return null;
    double d(Object? v) => v is num ? v.toDouble() : 0;
    return KeptBook(
      Book(
        id: '${j['id']}',
        title: '${j['title'] ?? ''}',
        author: '${j['author'] ?? ''}',
        narrator: '${j['narrator'] ?? ''}',
        duration: d(j['duration']),
        cover: '${j['cover'] ?? ''}',
        chapters: [
          for (final c in (j['chapters'] as List? ?? const []))
            if (c is Map) Chapter(d(c['start']), d(c['end']), '${c['title'] ?? ''}'),
        ],
      ),
      [
        for (final t in (j['tracks'] as List? ?? const []))
          if (t is Map) BookTrack(d(t['start']), d(t['duration']), '${t['file']}', '${t['mime'] ?? ''}'),
      ],
    );
  }
}

class BookDownloads {
  const BookDownloads({this.kept = const {}, this.progress = const {}, this.failed = const {}});
  final Map<String, KeptBook> kept;
  final Map<String, double> progress; // book id -> 0..1 while downloading
  final Map<String, String> failed; // book id -> why
}

String _ext(String mime, String url) {
  final fromUrl = p.extension(Uri.tryParse(url)?.path ?? '').replaceFirst('.', '');
  if (fromUrl.isNotEmpty && fromUrl.length <= 4) return fromUrl;
  return switch (mime) {
    'audio/mpeg' => 'mp3',
    'audio/flac' => 'flac',
    'audio/ogg' || 'audio/opus' => 'ogg',
    _ => 'm4b',
  };
}

class BookDownloadsNotifier extends Notifier<BookDownloads> {
  final _stop = <String>{};

  @override
  BookDownloads build() {
    final kept = <String, KeptBook>{};
    try {
      for (final e in (jsonDecode(prefs.getString('bookDownloads') ?? '[]') as List)) {
        final k = KeptBook.fromJson(e);
        if (k != null) kept[k.book.id] = k;
      }
    } catch (_) {}
    return BookDownloads(kept: kept);
  }

  void _save(Map<String, KeptBook> kept) =>
      prefs.setString('bookDownloads', jsonEncode([for (final k in kept.values) k.toJson()]));

  static Future<Directory> Function(String bookId) dir = (bookId) async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'audiobooks', bookId));

  /// Download a book's files (from a play session, so the addresses carry your token).
  Future<void> download(AbsAccount a, Book b, {HttpClient? http, AbsClient? client}) async {
    if (state.kept.containsKey(b.id) || state.progress.containsKey(b.id)) return;
    _stop.remove(b.id);
    state = BookDownloads(kept: state.kept, progress: {...state.progress, b.id: 0}, failed: {...state.failed}..remove(b.id));
    _system.invokeMethod('downloading', {'count': 1}).catchError((_) => null); // the phone keeps Encore running
    final c = client ?? AbsClient(a);
    final h = http ?? HttpClient();
    try {
      final (session, tracks, _) = await c.play(b.id);
      c.close(session, 0, b.duration).catchError((_) {});
      final full = await c.book(b.id).catchError((_) => b);
      final d = await dir(b.id);
      final total = tracks.fold<double>(0, (s, t) => s + t.duration);
      var done = 0.0;
      final local = <BookTrack>[];
      for (final (i, t) in tracks.indexed) {
        final f = File(p.join(d.path, '${i.toString().padLeft(3, '0')}.${_ext(t.mime, t.url)}'));
        await resumableDownload(h, Uri.parse(t.url), f, cancelled: () => _stop.contains(b.id), onProgress: (got, all) {
          final part = all == null || all == 0 ? 0.0 : got / all;
          _progress(b.id, total == 0 ? 0 : (done + part * t.duration) / total);
        });
        done += t.duration;
        local.add(BookTrack(t.start, t.duration, f.path, t.mime));
      }
      final kept = {...state.kept, b.id: KeptBook(full, local)};
      _save(kept);
      state = BookDownloads(kept: kept, progress: {...state.progress}..remove(b.id), failed: state.failed);
    } catch (e) {
      final stopped = e is DownloadCancelled;
      state = BookDownloads(
        kept: state.kept,
        progress: {...state.progress}..remove(b.id),
        failed: stopped ? state.failed : {...state.failed, b.id: '$e'},
      );
    } finally {
      c.dispose();
      if (http == null) h.close();
      if (state.progress.isEmpty) _system.invokeMethod('downloading', {'count': 0}).catchError((_) => null);
    }
  }

  void _progress(String id, double x) {
    if (!state.progress.containsKey(id)) return;
    state = BookDownloads(kept: state.kept, progress: {...state.progress, id: x.clamp(0, 1).toDouble()}, failed: state.failed);
  }

  void cancel(String id) => _stop.add(id);

  Future<void> remove(String id) async {
    final kept = {...state.kept}..remove(id);
    _save(kept);
    state = BookDownloads(kept: kept, progress: state.progress, failed: state.failed);
    try {
      final d = await dir(id);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}

final bookDownloadsProvider = NotifierProvider<BookDownloadsNotifier, BookDownloads>(BookDownloadsNotifier.new);
