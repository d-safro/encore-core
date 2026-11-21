import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'cover_cache.dart';

/// Covers kept on the phone for the downloaded songs (the song's own picture, its album's, its artist's,
/// and the playlists it's in), so they show with no server: in the app, on the lock screen, in the media
/// notification, on the home-screen widget and in the car.
///
/// Unlike the picture cache (which Android may empty, and which keeps whatever you browsed), these stay as
/// long as the songs do. Two sizes of each: a small one for lists and a larger one for the player and the
/// lock screen. Pictures that are the same (every song of an album usually has its album's cover) are kept
/// once.
class SavedCovers {
  SavedCovers._(this.dir);

  /// The folder the pictures (and the list of what's what) are kept in.
  final Directory dir;

  static const small = 200, large = 600;
  static const sizes = [small, large];

  /// `server|cover id|size` -> file name in [dir]; '' means the server has no picture for it.
  final _index = <String, String>{};
  Timer? _saveSoon;
  var _writes = 0; // each write its own temporary name: two songs with the same picture may arrive at once

  File get _indexFile => File(p.join(dir.path, 'index.json'));

  static Future<SavedCovers> open(Directory dir) async {
    final s = SavedCovers._(dir);
    try {
      await dir.create(recursive: true);
      if (await s._indexFile.exists()) {
        final m = jsonDecode(await s._indexFile.readAsString()) as Map;
        m.forEach((k, v) => s._index['$k'] = '$v');
      }
    } catch (_) {
      // a damaged list: start again (the pictures are fetched again with the next downloads)
      s._index.clear();
    }
    return s;
  }

  static String _key(String server, String id, int size) => '$server|$id|$size';

  /// The saved picture of [id] at [size], or null when there isn't one.
  File? file(String server, String id, int size) {
    final name = _index[_key(server, id, size)];
    return name == null || name.isEmpty ? null : File(p.join(dir.path, name));
  }

  /// The saved picture that best fits something [px] pixels wide, and its size: the small one for small
  /// spaces, else the large one (whichever there is when only one is saved).
  (File, int)? best(String server, String id, int px) {
    final order = px <= small ? const [small, large] : const [large, small];
    for (final size in order) {
      final f = file(server, id, size);
      if (f != null) return (f, size);
    }
    return null;
  }

  /// Both sizes of [id] are known (saved, or the server has none).
  bool has(String server, String id) => sizes.every((s) => _index.containsKey(_key(server, id, s)));

  /// Keeps [bytes] as the picture of [id] at [size]. Navidrome's "no cover" image (or an error) is noted as
  /// "none", so it isn't asked for again.
  Future<void> save(String server, String id, int size, List<int> bytes) async {
    final key = _key(server, id, size);
    if (isNoCover(bytes)) {
      _index[key] = '';
    } else {
      final name = '${md5.convert(bytes)}.jpg';
      final f = File(p.join(dir.path, name));
      if (!await f.exists()) {
        final tmp = File('${f.path}.${_writes++}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(f.path);
      }
      final old = _index[key];
      _index[key] = name;
      if (old != null && old.isNotEmpty && old != name) await _deleteIfUnused(old);
    }
    _scheduleSave();
  }

  /// Saves both sizes of every cover in [ids] that isn't on the phone yet, a few at a time.
  /// [fetch] returns the picture's bytes, null when the server has none, and throws when the server can't
  /// be reached: then this stops (what's saved so far stays) and rethrows. One that takes too long
  /// ([TimeoutException]: e.g. an artist photo the server is still looking for online) is skipped for now,
  /// unless several in a row do. [stop]: give up early.
  Future<int> fill(
    String server,
    Iterable<String> ids,
    Future<List<int>?> Function(String id, int size) fetch, {
    bool Function()? stop,
    int parallel = 4,
  }) async {
    final todo = [
      for (final id in ids.toSet())
        for (final size in sizes)
          if (id.isNotEmpty && !_index.containsKey(_key(server, id, size))) (id, size),
    ];
    var saved = 0;
    var next = 0;
    Object? failed;
    var slow = 0; // timeouts in a row
    Future<void> worker() async {
      while (failed == null && next < todo.length && !(stop?.call() ?? false)) {
        final (id, size) = todo[next++];
        try {
          final bytes = await fetch(id, size);
          await save(server, id, size, bytes ?? const []);
          if (bytes != null && !isNoCover(bytes)) saved++;
          slow = 0;
        } on TimeoutException catch (e) {
          if (++slow >= 6) failed ??= e; // not one slow picture: the server isn't answering
        } catch (e) {
          failed ??= e;
        }
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
    await flush();
    if (failed != null) throw failed!;
    return saved;
  }

  /// Forgets [server]'s pictures for covers not in [keep] (their songs were removed) and deletes the files
  /// nothing uses any more. Returns how many files went.
  Future<int> keepOnly(String server, Set<String> keep) async {
    final prefix = '$server|';
    _index.removeWhere((k, _) {
      if (!k.startsWith(prefix)) return false;
      final id = k.substring(prefix.length, k.lastIndexOf('|'));
      return !keep.contains(id);
    });
    final used = _index.values.toSet();
    var gone = 0;
    try {
      await for (final f in dir.list(followLinks: false)) {
        final name = p.basename(f.path);
        if (f is! File || name == 'index.json' || used.contains(name)) continue;
        try {
          await f.delete();
          gone++;
        } catch (_) {}
      }
    } catch (_) {}
    await flush();
    return gone;
  }

  /// The space the saved pictures take, in bytes.
  Future<int> bytes() async {
    var n = 0;
    try {
      await for (final f in dir.list(followLinks: false)) {
        if (f is File) n += await f.length();
      }
    } catch (_) {}
    return n;
  }

  Future<void> _deleteIfUnused(String name) async {
    if (_index.values.contains(name)) return;
    try {
      await File(p.join(dir.path, name)).delete();
    } catch (_) {}
  }

  void _scheduleSave() {
    _saveSoon?.cancel();
    _saveSoon = Timer(const Duration(seconds: 2), flush);
  }

  /// Writes the list of what's saved now (it's otherwise written a moment after the last change).
  Future<void> flush() async {
    _saveSoon?.cancel();
    _saveSoon = null;
    try {
      final tmp = File('${_indexFile.path}.${_writes++}.tmp');
      await tmp.writeAsString(jsonEncode(_index), flush: true);
      await tmp.rename(_indexFile.path);
    } catch (_) {}
  }
}

/// The phone's saved covers (opened as the app starts; null before that, and in tests that don't open it).
SavedCovers? savedCovers;

/// How other apps (Android Auto) are handed a saved picture: they can't read Encore's own files, so the
/// app shares the covers folder, read-only (CoverArtProvider.kt).
Uri sharedCoverUri(File f) => Uri.parse('content://dev.safro.encore.covers/${p.basename(f.path)}');
