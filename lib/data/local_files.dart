import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Music that's simply on this device, in no server library: the phone's audio (MediaStore, Android) or the
/// folders you pick on the desktop (lib/desktop/local_folders.dart), and files you open with Encore.
///
/// They're songs like the others (search, the queue, playing offline), with ids starting `lf-`. They're
/// private: never sent to the server, scrobbled, reported as "now playing", hearted there or used for its
/// recommendations. Encore's own downloads aren't listed again (they're in its private folder).
///
/// Shared code: this file. Where the songs come from is a [LocalSource] set at start-up by the platform code.

const localPrefix = 'lf-';
bool isLocalFileId(String id) => id.startsWith(localPrefix);

/// The id for a file (its path or content:// address): stable, so the queue and playlists keep it.
String localId(String uri) => '$localPrefix${sha1.convert(utf8.encode(uri)).toString().substring(0, 20)}';

class LocalTrack {
  const LocalTrack({
    required this.uri,
    required this.title,
    this.artist = '',
    this.album = '',
    this.track,
    this.year,
    this.duration,
    this.cover = '',
    this.mtime = 0,
  });
  final String uri; // a file path, or a content:// address on Android
  final String title, artist, album;
  final int? track, year, duration; // duration in seconds
  final String cover; // 'file:<path>' of its picture, or ''
  final int mtime; // ms: scanned again only when the file changed

  String get id => localId(uri);

  Song toSong() => Song(
    id: id,
    title: title,
    artist: artist,
    album: album,
    coverArt: cover,
    track: track,
    year: year,
    duration: duration,
    suffix: p.extension(Uri.tryParse(uri)?.path ?? uri).replaceFirst('.', '').toLowerCase(),
    path: uri,
  );

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'title': title,
    'artist': artist,
    'album': album,
    'track': ?track,
    'year': ?year,
    'duration': ?duration,
    'cover': cover,
    'mtime': mtime,
  };

  static LocalTrack? fromJson(Object? j) {
    if (j is! Map || j['uri'] == null) return null;
    int? n(Object? v) => v is num ? v.toInt() : null;
    return LocalTrack(
      uri: '${j['uri']}',
      title: '${j['title'] ?? ''}',
      artist: '${j['artist'] ?? ''}',
      album: '${j['album'] ?? ''}',
      track: n(j['track']),
      year: n(j['year']),
      duration: n(j['duration']),
      cover: '${j['cover'] ?? ''}',
      mtime: n(j['mtime']) ?? 0,
    );
  }
}

/// "Song Title" from "03 - Artist - Song Title.flac" when a file has no tags.
String titleFromFileName(String path) {
  var t = p.basenameWithoutExtension(path).replaceAll('_', ' ').trim();
  t = t.replaceFirst(RegExp(r'^\d{1,3}[\s.\-]+'), '');
  final dash = t.lastIndexOf(' - ');
  if (dash > 0) t = t.substring(dash + 3);
  return t.trim().isEmpty ? p.basename(path) : t.trim();
}

/// Where pictures taken from files are kept (shared by every [LocalSource]).
Future<Directory> localCoversDir() async =>
    Directory(p.join((await getApplicationSupportDirectory()).path, 'local-covers'));

/// The tags of a file (title, artist, album, track, year, length, the embedded picture), read in Dart
/// (MP3, FLAC, M4A, OGG / Opus, WAV, AIFF, APE). The picture is saved into [coversDir]; a file whose tags
/// can't be read gets its name as the title.
Future<LocalTrack> readTags(File f, {Directory? coversDir}) async {
  final stat = await f.stat();
  try {
    final m = readMetadata(f, getImage: coversDir != null);
    var cover = '';
    if (coversDir != null && m.pictures.isNotEmpty) {
      final pic = m.pictures.first;
      final ext = pic.mimetype.contains('png') ? 'png' : 'jpg';
      final key = sha1.convert(pic.bytes).toString().substring(0, 20); // an album's songs share one picture
      final out = File(p.join(coversDir.path, '$key.$ext'));
      if (!await out.exists()) {
        await coversDir.create(recursive: true);
        await out.writeAsBytes(pic.bytes);
      }
      cover = 'file:${out.path}';
    }
    final title = (m.title ?? '').trim();
    return LocalTrack(
      uri: f.path,
      title: title.isEmpty ? titleFromFileName(f.path) : title,
      artist: (m.artist ?? m.albumArtist ?? '').trim(),
      album: (m.album ?? '').trim(),
      track: m.trackNumber,
      year: m.year?.year,
      duration: m.duration?.inSeconds,
      cover: cover,
      mtime: stat.modified.millisecondsSinceEpoch,
    );
  } catch (_) {
    return LocalTrack(uri: f.path, title: titleFromFileName(f.path), mtime: stat.modified.millisecondsSinceEpoch);
  }
}

/// The file types Encore lists from folders.
const localAudioExtensions = {'mp3', 'flac', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'wav', 'aiff', 'aif', 'ape', 'wma', 'alac', 'mka', 'webm'};

bool isAudioFile(String path) => localAudioExtensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

/// Where a platform finds the device's music.
abstract class LocalSource {
  /// Whether it may look (Android: the "music and audio" permission). [ask]: ask for it if not yet.
  Future<bool> allowed({bool ask = false});

  /// Every song it finds now; [known] are the last ones found (by uri), so unchanged files aren't read again.
  Future<List<LocalTrack>> scan(Map<String, LocalTrack> known);

  /// Fires when something may have changed (a watched folder), so the list is scanned again.
  Stream<void> get changes => const Stream.empty();
}

/// Set at start-up by the platform (Android: MediaStoreSource below; desktop: lib/desktop/local_folders.dart).
LocalSource? localSource;

/// A cover id to show anywhere but here: a local file's picture is a path on this device (with your home
/// folder's name in it), so it's left out of what other devices and Jam guests are sent.
String shareableCover(String coverArt) => coverArt.startsWith('file:') ? '' : coverArt;

/// The queue as another device can play it: only server songs, and where [index] lands among them (the next
/// server song when the one playing is a file on this device). Empty when there's none.
(List<String>, int) serverQueue(List<Song> songs, int index) {
  final ids = <String>[];
  var at = -1;
  for (final (i, s) in songs.indexed) {
    if (isLocalFileId(s.id)) continue;
    if (i >= index && at < 0) at = ids.length;
    ids.add(s.id);
  }
  return (ids, at < 0 ? 0 : at);
}

// ── Opening a file that isn't in the list ("Open with Encore", a file dropped on the window) ──
final _opened = <String, LocalTrack>{};

/// Where a local song's audio is: its file path, or content:// address (the handler plays from it).
String? localUriFor(String id) => _byId[id]?.uri ?? _opened[id]?.uri;

Map<String, LocalTrack> _byId = {};

/// A file opened with Encore: remembered for this session so it plays, and shown as a song.
Song openedFile(LocalTrack t) {
  _opened[t.id] = t;
  return t.toSong();
}

// ── The list ──
class LocalLibrary {
  const LocalLibrary({this.tracks = const [], this.scanning = false, this.allowed = true, this.loaded = false});
  final List<LocalTrack> tracks;
  final bool scanning, allowed, loaded;

  List<Song> get songs => [for (final t in tracks) t.toSong()];

  /// Songs whose title, artist or album has every word of [q].
  List<Song> search(String q) {
    final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    return [
      for (final t in tracks)
        if (words.every((w) => '${t.title} ${t.artist} ${t.album}'.toLowerCase().contains(w))) t.toSong(),
    ];
  }
}

/// Sorted for showing: artist, album, track, title.
List<LocalTrack> sortTracks(Iterable<LocalTrack> t) => t.toList()
  ..sort((a, b) {
    int c(String x, String y) => x.toLowerCase().compareTo(y.toLowerCase());
    final r = c(a.artist, b.artist);
    if (r != 0) return r;
    final al = c(a.album, b.album);
    if (al != 0) return al;
    final tr = (a.track ?? 0).compareTo(b.track ?? 0);
    return tr != 0 ? tr : c(a.title, b.title);
  });

class LocalLibraryNotifier extends Notifier<LocalLibrary> {
  StreamSubscription<void>? _sub;
  Timer? _again;
  bool _scanned = false; // a scan finished: the saved list (still loading) mustn't replace what it found

  /// Where the list is kept between runs (a test can point it elsewhere).
  static Future<File> Function() store = () async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'local-library.json'));

  @override
  LocalLibrary build() {
    ref.onDispose(() {
      _sub?.cancel();
      _again?.cancel();
    });
    _load();
    return const LocalLibrary();
  }

  void _set(List<LocalTrack> tracks, {bool? scanning, bool? allowed, bool loaded = true}) {
    _byId = {for (final t in tracks) t.id: t};
    state = LocalLibrary(
      tracks: tracks,
      scanning: scanning ?? state.scanning,
      allowed: allowed ?? state.allowed,
      loaded: loaded,
    );
  }

  Future<void> _load() async {
    try {
      final f = await store();
      if (await f.exists()) {
        final list = [
          for (final j in jsonDecode(await f.readAsString()) as List) ?LocalTrack.fromJson(j),
        ];
        if (!_scanned) _set(sortTracks(list));
      } else if (!_scanned) {
        _set(const [], loaded: true);
      }
    } catch (_) {
      if (!_scanned) _set(const []);
    }
    final src = localSource;
    if (src == null) return;
    _sub ??= src.changes.listen((_) {
      _again?.cancel();
      _again = Timer(const Duration(seconds: 3), () => refresh()); // a burst of changes: one scan
    });
    if (await src.allowed()) unawaited(refresh());
  }

  /// Look for songs again. [ask]: ask for the permission first if needed (Android).
  Future<void> refresh({bool ask = false}) async {
    final src = localSource;
    if (src == null || state.scanning) return;
    if (!await src.allowed(ask: ask)) {
      state = LocalLibrary(tracks: state.tracks, allowed: false, loaded: true);
      return;
    }
    state = LocalLibrary(tracks: state.tracks, scanning: true, loaded: state.loaded);
    try {
      final found = sortTracks(await src.scan({for (final t in state.tracks) t.uri: t}));
      _scanned = true;
      _set(found, scanning: false, allowed: true);
      final f = await store();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode([for (final t in found) t.toJson()]));
    } catch (_) {
      state = LocalLibrary(tracks: state.tracks, scanning: false, loaded: true);
    }
  }
}

final localLibraryProvider = NotifierProvider<LocalLibraryNotifier, LocalLibrary>(LocalLibraryNotifier.new);
