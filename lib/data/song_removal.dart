import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../playback/handler.dart';
import 'account.dart';
import 'events.dart';
import 'library.dart';
import 'subsonic.dart';

/// "Remove from library": take a song out of every library on the server for good (Conductor's
/// `encore.removeSongs`, from 1.7; admins only). Asked about first ([SongRemoval]: the song and its other copies,
/// with their files), shown, confirmed, then exactly those are removed. Every device hears (`songsRemoved`) and
/// drops its download and its queue's copies ([songsRemovedProvider]).

/// One song (file) that removing would delete.
class RemovalFile {
  const RemovalFile({
    required this.id,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.library = '',
    this.path = '',
    this.size = 0,
  });

  final String id, title, artist, album, library, path;
  final int size; // bytes

  factory RemovalFile.fromJson(Map<String, dynamic> j) => RemovalFile(
    id: '${j['id'] ?? ''}',
    title: '${j['title'] ?? ''}',
    artist: '${j['artist'] ?? ''}',
    album: '${j['album'] ?? ''}',
    library: '${j['library'] ?? ''}',
    path: '${j['path'] ?? ''}',
    size: (j['size'] as num?)?.toInt() ?? 0,
  );
}

/// What removing would delete: the songs asked about first, then their other copies.
class SongRemoval {
  const SongRemoval(this.files);
  final List<RemovalFile> files;

  int get size => files.fold(0, (n, f) => n + f.size);
}

Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

extension SongRemovalCalls on SubsonicClient {
  /// What removing these songs would delete (admins; others get error 50).
  Future<SongRemoval> songRemoval(List<String> ids) async {
    final r = _m((await call('getSongRemoval', {'id': ids}))['songRemoval']);
    final list = r['song'] is List ? r['song'] as List : const [];
    return SongRemoval([for (final x in list) RemovalFile.fromJson(_m(x))]);
  }

  /// Delete these songs for good. Returns the ones removed.
  Future<List<String>> removeSongs(List<String> ids) async {
    final r = _m((await call('removeSongs', {'id': ids, 'confirm': 'permanently'}))['songsRemoved']);
    return r['removed'] is List ? [for (final x in r['removed'] as List) '$x'] : const [];
  }
}

/// Whether the server can remove songs for good (`encore.removeSongs`).
final songRemovalOfferedProvider = FutureProvider<bool>((ref) async {
  final c = ref.watch(clientProvider);
  if (c == null) return false;
  final names = await c.openSubsonicExtensions();
  if (names.isEmpty) {
    final again = Timer(const Duration(seconds: 30), ref.invalidateSelf); // no answer: ask again soon
    ref.onDispose(again.cancel);
  }
  return names.contains('encore.removeSongs');
});

/// This device lets go of songs removed for good: its downloads of them, and their places in the queue.
Future<void> forgetRemovedSongs(DownloadsNotifier downloads, Iterable<String> ids) async {
  final gone = ids.toSet();
  if (gone.isEmpty) return;
  await downloads.remove(gone);
  final songs = audioHandler.songs;
  for (var i = songs.length - 1; i >= 0; i--) {
    if (gone.contains(songs[i].id)) await audioHandler.removeQueueItemAt(i);
  }
}

/// Listens for `songsRemoved` (an admin removed songs, here or on another device). Watched by the app.
final songsRemovedProvider = Provider<void>((ref) {
  final live = ref.watch(liveEventsProvider);
  final sub = live?.events.where((e) => e.type == 'songsRemoved').listen((e) {
    final ids = e.data['ids'];
    if (ids is List) unawaited(forgetRemovedSongs(ref.read(downloadsProvider.notifier), [for (final x in ids) '$x']));
  });
  ref.onDispose(() => sub?.cancel());
});
