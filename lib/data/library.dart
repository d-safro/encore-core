import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/settings.dart';
import 'account.dart';
import 'db.dart';
import 'models.dart';
import 'song_download.dart';
import 'usb_link.dart';
import 'subsonic.dart';

late LibraryDb libraryDb; // opened in main() before runApp

final dbProvider = Provider<LibraryDb>((ref) => libraryDb);

// ── Network ──
final connectivityProvider = StreamProvider<List<ConnectivityResult>>((ref) async* {
  final c = Connectivity();
  yield await c.checkConnectivity();
  yield* c.onConnectivityChanged;
});

final onWifiProvider = Provider<bool>((ref) {
  final r = ref.watch(connectivityProvider).value ?? const [];
  return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
});

/// No network at all.
final noNetworkProvider = Provider<bool>((ref) {
  final r = ref.watch(connectivityProvider).value;
  return r != null && (r.isEmpty || r.every((e) => e == ConnectivityResult.none));
});

/// Can the server be reached right now? Checked with a quick ping when the app starts, when the network
/// changes, after a request fails, and every 20 s while it's away (every 2 min while it's there). So when the
/// phone has internet but the server is away (Tailscale off, the laptop asleep), the app switches to what's on
/// the phone within seconds instead of waiting on every request.
class ServerReachNotifier extends Notifier<bool> {
  Timer? _timer;
  bool _checking = false;

  @override
  bool build() {
    ref.watch(clientProvider);
    ref.watch(connectivityProvider);
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(check);
    return true; // optimistic until the first ping answers
  }

  Future<void> check() async {
    final c = ref.read(clientProvider);
    if (c == null || ref.read(noNetworkProvider) || _checking) return;
    _checking = true;
    var ok = false;
    try {
      await c.call('ping', const {}, null, const Duration(seconds: 6));
      ok = true;
    } on SubsonicException catch (e) {
      ok = e.code != 0; // the server answered (even "wrong password" means it's there)
    } catch (_) {
      ok = false;
    } finally {
      _checking = false;
    }
    if (state != ok) state = ok;
    _timer?.cancel();
    _timer = Timer(ok ? const Duration(minutes: 2) : const Duration(seconds: 20), check);
  }

  /// A request just failed with a network error: check now.
  void suspect() {
    if (state) check();
  }
}

extension CacheFor on Ref {
  /// Keep the answer for [d] after the last screen using it closes, so going back is instant.
  void cacheFor(Duration d) {
    final link = keepAlive();
    Timer? t;
    onCancel(() => t = Timer(d, link.close));
    onResume(() => t?.cancel());
    onDispose(() => t?.cancel());
  }
}

/// Hearts changed in this session, by song id: lists that were loaded earlier show the new state.
class HeartsNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};
  void set(String id, bool on) => state = {...state, id: on};
}

final heartsProvider = NotifierProvider<HeartsNotifier, Map<String, bool>>(HeartsNotifier.new);

final serverReachableProvider = NotifierProvider<ServerReachNotifier, bool>(ServerReachNotifier.new);

/// Offline = switched to offline mode in settings, no network at all, or the server can't be reached.
final offlineProvider = Provider<bool>((ref) {
  if (ref.watch(settingsProvider.select((s) => s.offlineMode))) return true;
  if (ref.watch(noNetworkProvider)) return true;
  return !ref.watch(serverReachableProvider);
});

/// Everything the screens read goes through here: the server when online, the local copy otherwise
/// (and as a fallback when the server can't be reached).
class Repo {
  Repo(this.client, this.db, this.offline, this.settings, {this.onNetworkError});
  final SubsonicClient? client;
  final LibraryDb db;
  final bool offline;
  final Settings settings;
  final void Function()? onNetworkError; // tells the reachability check to look again

  bool get online => client != null && !offline;

  Future<T> _either<T>(Future<T> Function(SubsonicClient c) remote, Future<T> Function() local) async {
    if (!online) return local();
    try {
      return await remote(client!);
    } on IOException {
      onNetworkError?.call();
      return local(); // no network, connection refused, TLS problems...
    } on TimeoutException {
      onNetworkError?.call();
      return local();
    } on http.ClientException {
      onNetworkError?.call();
      return local();
    }
  }

  String _orderFor(String type) => switch (type) {
    'newest' => 'created DESC',
    'alphabeticalByArtist' => 'artist_lc, year',
    'byYear' => 'year DESC',
    'frequent' => 'play_count DESC',
    'random' => 'RANDOM()',
    _ => 'name_lc',
  };

  Future<List<Album>> albums(String type, {int size = 50, int offset = 0, String? genre}) => _either(
    (c) => c
        .albumList(genre != null ? 'byGenre' : type, size: size, offset: offset, genre: genre)
        .then((l) => settings.showLookup ? l : l.where((a) => !a.isLookup).toList()),
    () => type == 'starred'
        ? db.albums().then((l) => l.where((a) => a.starred).toList())
        : type == 'recent' && genre == null
        ? _downloadedAlbums(offset > 0 ? 0 : size)
        : db.albums(orderBy: _orderFor(type), limit: size, offset: offset, genre: genre),
  );

  /// Offline stand-in for "recently played": albums you have songs downloaded from, newest download first.
  Future<List<Album>> _downloadedAlbums(int size) async {
    final ids = <String>[];
    for (final (song, _, _) in await db.downloads()) {
      if (song.albumId.isNotEmpty && !ids.contains(song.albumId)) ids.add(song.albumId);
      if (ids.length >= size) break;
    }
    final out = <Album>[];
    for (final id in ids) {
      final a = await db.album(id);
      if (a != null) out.add(a);
    }
    return out;
  }

  Future<Album> album(String id) => _either((c) async {
    final a = await c.album(id);
    if (settings.showLookup) return a;
    return Album(
      id: a.id,
      name: a.name,
      artist: a.artist,
      artistId: a.artistId,
      coverArt: a.coverArt,
      genre: a.genre,
      year: a.year,
      songCount: a.songCount,
      duration: a.duration,
      starred: a.starred,
      created: a.created,
      userRating: a.userRating,
      songs: a.songs.where((s) => !s.isLookup).toList(),
    );
  }, () async => (await db.album(id)) ?? (throw Exception('This album isn\'t saved on the phone')));

  Future<List<Artist>> artists() => _either((c) => c.artists(), db.artists);

  Future<Artist> artist(String id) => _either((c) async {
    final a = await c.artist(id);
    if (settings.showLookup) return a;
    return Artist(
      id: a.id,
      name: a.name,
      coverArt: a.coverArt,
      starred: a.starred,
      albums: a.albums.where((x) => !x.isLookup).toList(),
    );
  }, () async => (await db.artist(id)) ?? (throw Exception('This artist isn\'t saved on the phone')));

  Future<List<Playlist>> playlists() => _either((c) => c.playlists(), db.playlists);

  Future<Playlist> playlist(String id) => _either((c) => c.playlist(id), () async {
    final pl = (await db.playlists()).firstWhere(
      (p) => p.id == id,
      orElse: () => throw Exception("This playlist isn't saved on the phone"),
    );
    return Playlist(id: pl.id, name: pl.name, comment: pl.comment, songs: await db.playlistSongs(id));
  });

  Future<SearchResult> search(String q) => _either((c) => c.search(q), () => db.search(q));

  Future<SearchResult> starred() => _either(
    (c) => c.starred(),
    () async =>
        SearchResult(songs: await db.starredSongs(), albums: (await db.albums()).where((a) => a.starred).toList()),
  );

  Future<List<Genre>> genres() => _either((c) => c.genres(), () async {
    final albums = await db.albums();
    final m = <String, int>{};
    for (final a in albums) {
      if (a.genre.isNotEmpty) m[a.genre] = (m[a.genre] ?? 0) + 1;
    }
    return m.entries.map((e) => Genre(e.key, 0, e.value)).toList()..sort((a, b) => a.name.compareTo(b.name));
  });

  Future<List<Song>> songsByGenre(String g) => _either((c) => c.songsByGenre(g), () => db.songsByGenre(g));

  Future<List<Song>> randomSongs({int size = 50, String? genre}) =>
      _either((c) => c.randomSongs(size: size, genre: genre), () async {
        // Offline: shuffle what's downloaded; only fall back to everything if nothing is.
        final downloaded = [for (final (song, _, _) in await db.downloads()) song];
        return (downloaded.isNotEmpty ? downloaded : await db.allSongs())..shuffle();
      }).then((l) => l.take(size).toList());

  /// Songs by id, in the same order: from the phone's copy first, the server for the rest.
  Future<List<Song>> resolveSongs(List<String> ids) async {
    final local = {for (final s in await db.songsByIds(ids)) s.id: s};
    final missing = ids.where((id) => !local.containsKey(id)).toList();
    if (missing.isNotEmpty && online) {
      for (var i = 0; i < missing.length; i += 8) {
        final batch = await Future.wait(
          missing.skip(i).take(8).map((id) => client!.song(id).then<Song?>((s) => s, onError: (_) => null)),
        );
        for (final s in batch.whereType<Song>()) {
          local[s.id] = s;
        }
      }
    }
    return [
      for (final id in ids)
        if (local[id] != null) local[id]!,
    ];
  }

  Future<List<Song>> allSongs({int size = 200, int offset = 0}) => _either(
    (c) => c
        .search('', songCount: size, offset: offset, artistCount: 0, albumCount: 0, client: 'Encore-sync')
        .then((r) => r.songs.where((s) => !s.isLookup).toList()),
    () => db.allSongs(limit: size, offset: offset),
  );
}

final repoProvider = Provider<Repo>(
  (ref) => Repo(
    ref.watch(clientProvider),
    ref.watch(dbProvider),
    ref.watch(offlineProvider),
    ref.watch(settingsProvider),
    onNetworkError: () => ref.read(serverReachableProvider.notifier).suspect(),
  ),
);

// ── Library sync (local copy for offline browsing / search) ──
class SyncState {
  final bool running;
  final String message;
  final DateTime? last;
  const SyncState({this.running = false, this.message = '', this.last});
}

class SyncNotifier extends Notifier<SyncState> {
  @override
  SyncState build() {
    ref.read(dbProvider).lastSync().then((d) {
      if (!state.running) state = SyncState(last: d);
    });
    return const SyncState();
  }

  /// Downloads the whole library index. Uses its own client name so music-lookup never mixes
  /// songs you don't have into the offline copy.
  Future<void> sync() async {
    final c = ref.read(clientProvider);
    if (c == null || state.running) return;
    const who = 'Encore-sync';
    try {
      state = const SyncState(running: true, message: 'Artists…');
      final artists = (await c.artists()).where((a) => !a.isLookup).toList();
      final albums = <Album>[];
      for (var off = 0; ; off += 500) {
        state = SyncState(running: true, message: 'Albums… ${albums.length}');
        final page = await c.albumList('alphabeticalByName', size: 500, offset: off, client: who);
        albums.addAll(page.where((a) => !a.isLookup));
        if (page.length < 500) break;
      }
      final songs = <Song>[];
      for (var off = 0; ; off += 500) {
        state = SyncState(running: true, message: 'Songs… ${songs.length}');
        final r = await c.search('', artistCount: 0, albumCount: 0, songCount: 500, offset: off, client: who);
        songs.addAll(r.songs.where((s) => !s.isLookup));
        if (r.songs.length < 500) break;
      }
      state = const SyncState(running: true, message: 'Playlists…');
      final playlists = await c.playlists();
      final plSongs = <String, List<String>>{};
      for (final p in playlists) {
        try {
          plSongs[p.id] = (await c.playlist(p.id)).songs.map((s) => s.id).toList();
        } catch (_) {} // one playlist that won't load shouldn't stop the whole sync
      }
      await ref
          .read(dbProvider)
          .replaceLibrary(artists: artists, albums: albums, songs: songs, playlists: playlists, playlistSongs: plSongs);
      state = SyncState(message: '${songs.length} songs, ${albums.length} albums saved', last: DateTime.now());
      ref.read(downloadsProvider.notifier).refreshPins();
    } catch (e) {
      state = SyncState(message: 'Sync failed: $e', last: state.last);
    }
  }
}

final syncProvider = NotifierProvider<SyncNotifier, SyncState>(SyncNotifier.new);

// ── Offline downloads ──
class DownloadsState {
  final Map<String, String> files; // song id -> local file path
  final Map<String, double> progress; // song id -> 0..1 while downloading
  final Set<String> pins; // collections kept downloaded: album:<id>, playlist:<id>, starred, library
  const DownloadsState({this.files = const {}, this.progress = const {}, this.pins = const {}});
  DownloadsState copy({Map<String, String>? files, Map<String, double>? progress, Set<String>? pins}) =>
      DownloadsState(files: files ?? this.files, progress: progress ?? this.progress, pins: pins ?? this.pins);
}

class DownloadsNotifier extends Notifier<DownloadsState> {
  StreamSubscription? _sub;

  // No duplicate files: the same recording that's in your library twice (album + compilation, a single and its
  // album...) is stored once, and every copy of it points at that file.
  final _copies = <String, List<(int?, String)>>{}; // artist|title -> (length, file) of what's on the phone
  final _inFlight = <String, List<(int?, String)>>{}; // artist|title -> (length, song id) downloading now
  final _waiting = <String, List<Song>>{}; // song id downloading -> other copies waiting for its file

  static String _norm(String x) => x
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?(remaster|version|edit|mono|stereo).*?\)|\s-\s.*(remaster|version).*$'), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
  static String _recording(Song s) => '${_norm(s.artist)}|${_norm(s.title)}';
  static bool _sameLength(int? a, int? b) => a == null || b == null || (a - b).abs() <= 2;

  String? _copyOf(Song s) {
    for (final (len, path) in _copies[_recording(s)] ?? const <(int?, String)>[]) {
      if (_sameLength(len, s.duration)) return path;
    }
    return null;
  }

  String? _downloadingCopyOf(Song s) {
    for (final (len, id) in _inFlight[_recording(s)] ?? const <(int?, String)>[]) {
      if (_sameLength(len, s.duration)) return id;
    }
    return null;
  }

  void _addCopy(Song s, String path) => (_copies[_recording(s)] ??= []).add((s.duration, path));

  /// Another song becomes downloaded by pointing at a file we already have (takes no space).
  Future<void> _alias(Song s, String path) async {
    await ref.read(dbProvider).addDownload(s, path, 0);
    state = state.copy(files: {...state.files, s.id: path}, progress: {...state.progress}..remove(s.id));
  }

  @override
  DownloadsState build() {
    _sub ??= FileDownloader().updates.listen(_onUpdate);
    ref.onDispose(() {
      _sub?.cancel();
      _disposed = true; // switched to another server: stop, keeping what has arrived
      _retry?.cancel();
      _net?.close(force: true);
      _system.invokeMethod('downloading', {'count': 0}).catchError((_) => null);
    });
    // carry on when downloading becomes possible again, and stop (keeping what has arrived) when it isn't
    ref.listen(offlineProvider, (a, b) => b ? _pump() : resume());
    ref.listen(onWifiProvider, (a, b) => b ? resume() : _pump());
    ref.listen(settingsProvider.select((s) => s.downloadWifiOnly), (a, b) => _pump());
    ref.listen(clientProvider, (a, b) => resume());
    ref.listen(usbLinkProvider, (a, b) => resume()); // cable in: carry on through it; out: over the network
    loaded = _loadFiles().then((_) {
      _loadQueue();
      // after start-up settles (the first ping of the server)
      Future.delayed(const Duration(seconds: 3), resume);
    });
    return DownloadsState(pins: (prefs.getStringList('downloadPins') ?? const []).toSet());
  }

  /// Done once the saved downloads are known (the player waits for it before restoring the queue).
  Future<void> loaded = Future.value();

  /// Loads the saved downloads, dropping any whose file is gone or isn't audio (e.g. a server error page).
  Future<void> _loadFiles() async {
    // files replaced by smaller copies while the player was using them
    for (final p in prefs.getStringList('deleteLater') ?? const <String>[]) {
      try {
        File(p).deleteSync();
      } catch (_) {}
    }
    prefs.remove('deleteLater');
    try {
      final rows = await ref.read(dbProvider).downloads();
      final m = {for (final (song, path, _) in rows) song.id: path};
      final bad = <String>[];
      final ok = <String, bool>{};
      for (final e in m.entries) {
        if (!(ok[e.value] ??= await _isAudio(e.value))) bad.add(e.key);
      }
      for (final (song, path, _) in rows) {
        if (ok[path] == true) _addCopy(song, path);
      }
      for (final id in bad) {
        try {
          await File(m.remove(id)!).delete();
        } catch (_) {}
        await ref.read(dbProvider).removeDownload(id);
      }
      state = state.copy(files: {...m, ...state.files});
    } catch (_) {}
  }

  /// A real song file: exists, isn't tiny, and doesn't start like a JSON / HTML / XML error reply.
  /// One quick look at the size for most files (this runs for every download at start-up); only
  /// small files, which is what an error reply would be, are opened.
  static Future<bool> _isAudio(String path) async {
    try {
      final f = File(path);
      final st = f.statSync();
      if (st.type == FileSystemEntityType.notFound) return false;
      final len = st.size;
      if (len < 8 * 1024) return false;
      if (len > 512 * 1024) return true;
      final raf = await f.open();
      try {
        final head = await raf.read(16);
        final first = head.firstWhere((b) => b > 32, orElse: () => 0);
        return first != 0x7B && first != 0x3C; // '{' or '<'
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  bool has(String id) => state.files.containsKey(id);

  // ── The download queue ──
  // Encore downloads songs itself (not through Android's download jobs) so that nothing is lost when a
  // download stops: the queue is saved, every song keeps what has arrived in a .part file, and when the app
  // is open again and can reach the server it carries on from the byte it reached (see resumableDownload).
  final _queue = <String, _Queued>{}; // song id -> what to fetch, in the order asked for
  final _running = <String>{};
  final _cancel = <String>{}; // running downloads to stop
  final _shown = <String, int>{}; // song id -> when its progress was last shown (ms)
  HttpClient? _net;
  Timer? _retry;
  bool _disposed = false;
  static const _parallel = 3;
  static const _parallelCable = 4; // the server converting songs is what limits it then
  static const _system = MethodChannel('encore/system');

  static Future<Directory> musicDir() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'music'));

  void _loadQueue() {
    try {
      for (final j in jsonDecode(prefs.getString('downloadQueue') ?? '[]') as List) {
        final q = _Queued.fromJson((j as Map).cast<String, dynamic>());
        if (!has(q.song.id)) _queue[q.song.id] = q;
      }
    } catch (_) {}
    for (final q in _queue.values) {
      (_inFlight[_recording(q.song)] ??= []).add((q.song.duration, q.song.id));
    }
    if (_queue.isNotEmpty) {
      state = state.copy(progress: {...state.progress, for (final id in _queue.keys) id: state.progress[id] ?? 0});
    }
  }

  void _saveQueue() {
    if (_disposed) return;
    prefs.setString('downloadQueue', jsonEncode([for (final q in _queue.values) q.toJson()]));
  }

  /// [manual]: picked one by one (song menu), so switching off a collection never removes it.
  Future<void> download(List<Song> songs, {bool manual = false}) async {
    if (manual) {
      prefs.setStringList(
        'manualDownloads',
        {...prefs.getStringList('manualDownloads') ?? const <String>[], ...songs.map((s) => s.id)}.toList(),
      );
    }
    await loaded; // what's on the phone and what was still on its way
    final s = ref.read(settingsProvider);
    final progress = {...state.progress};
    for (final song in songs.where((x) => !x.isLookup && !has(x.id))) {
      if (_queue.containsKey(song.id)) continue; // already on its way
      final copy = _copyOf(song);
      if (copy != null) {
        await _alias(song, copy); // the same recording is already on the phone
        continue;
      }
      final twin = _downloadingCopyOf(song);
      if (twin != null) {
        (_waiting[twin] ??= []).add(song); // gets that file when it arrives
        continue;
      }
      _queue[song.id] = _Queued(song, s.downloadFormat, s.downloadBitrate);
      (_inFlight[_recording(song)] ??= []).add((song.duration, song.id));
      progress[song.id] = 0;
    }
    state = state.copy(progress: progress);
    _saveQueue();
    _pump();
  }

  /// Carry on with the queue now (the app came back, the server is reachable again...): songs that failed
  /// a moment ago try again straight away.
  void resume() {
    for (final q in _queue.values) {
      q.waitUntil = null;
    }
    _pump();
  }

  /// Songs still to download (for the downloads screen).
  int get queued => _queue.length;

  bool get _allowed {
    if (_disposed || ref.read(clientProvider) == null) return false;
    if (ref.read(usbLinkProvider)) return true; // plugged into the server's computer: through the cable
    if (ref.read(offlineProvider)) return false;
    return !ref.read(settingsProvider).downloadWifiOnly || ref.read(onWifiProvider);
  }

  void _pump() {
    if (_disposed) return;
    if (!_allowed) {
      // e.g. left Wi-Fi with "Wi-Fi only" on: stop, keeping what has arrived
      _cancel.addAll(_running);
      _keepAwake();
      return;
    }
    final now = DateTime.now();
    DateTime? next;
    for (final q in _queue.values.toList()) {
      if (_running.length >= (ref.read(usbLinkProvider) ? _parallelCable : _parallel)) break;
      if (_running.contains(q.song.id)) continue;
      final w = q.waitUntil;
      if (w != null && w.isAfter(now)) {
        if (next == null || w.isBefore(next)) next = w;
        continue;
      }
      _run(q);
    }
    _retry?.cancel();
    if (next != null) _retry = Timer(next.difference(now), _pump);
    _keepAwake();
  }

  /// Keeps Encore running while songs download with the app in the background (a "Downloading" notification),
  /// like Spotify. Without it Android pauses the app soon after you leave it.
  void _keepAwake() {
    final n = _running.isNotEmpty ? _queue.length : 0;
    _system.invokeMethod('downloading', {'count': n}).catchError((_) => null);
  }

  Future<void> _run(_Queued q) async {
    final id = q.song.id;
    final c = ref.read(clientProvider);
    if (c == null) return;
    _running.add(id);
    final raw = q.format == 'raw';
    var url = raw ? c.downloadUrl(id) : c.streamUrl(id, format: q.format, maxBitRate: q.kbps);
    if (ref.read(usbLinkProvider)) url = UsbLinkNotifier.viaCable(url); // plugged in: through the cable
    final ext = raw ? (q.song.suffix.isEmpty ? 'mp3' : q.song.suffix) : q.format;
    final guess = raw ? q.song.size : sizeAt(q.song, q.kbps); // when the server doesn't say how big
    try {
      final dir = await musicDir();
      final net = _net ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..idleTimeout = const Duration(seconds: 30);
      final f = await resumableDownload(
        net,
        url,
        File(p.join(dir.path, '$id.$ext')),
        onProgress: (got, total) => _progress(id, got, total ?? guess),
        cancelled: () => _disposed || _cancel.contains(id),
      );
      q.tries = 0;
      if (!_disposed) await _done(q, f.path);
    } on DownloadCancelled {
      // removed: its partial file goes too; otherwise it carries on later from where it stopped
      if (!_disposed && !_queue.containsKey(id)) await _deletePart(id);
    } on DownloadFailed catch (e) {
      if (e.permanent) {
        await _drop(q); // the song is gone from the server
      } else {
        _later(q);
      }
    } catch (_) {
      _later(q); // no signal, the server went away...: kept, and tried again
    } finally {
      _running.remove(id);
      _cancel.remove(id);
      _shown.remove(id);
      _pump();
    }
  }

  /// Try this song again later: 15 s, 30 s, 1 min ... at most every 10 min (sooner when the app comes back).
  void _later(_Queued q) {
    q.tries++;
    q.waitUntil = DateTime.now().add(Duration(seconds: (15 << (q.tries - 1).clamp(0, 6)).clamp(15, 600)));
  }

  void _progress(String id, int got, int? total) {
    if (_disposed || !_queue.containsKey(id)) return; // removed meanwhile
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_shown[id] ?? 0) < 400) return; // a few times a second is plenty
    _shown[id] = now;
    final v = total == null || total <= 0 ? 0.0 : (got / total).clamp(0.0, 0.99);
    state = state.copy(progress: {...state.progress, id: v});
  }

  Future<void> _done(_Queued q, String path) async {
    final id = q.song.id;
    if (!await _isAudio(path)) {
      // The server answered with an error instead of the song; don't keep it as a download.
      try {
        await File(path).delete();
      } catch (_) {}
      await _drop(q);
      return;
    }
    _queue.remove(id);
    _saveQueue();
    await ref.read(dbProvider).addDownload(q.song, path, await File(path).length());
    _addCopy(q.song, path);
    _inFlight[_recording(q.song)]?.removeWhere((e) => e.$2 == id);
    state = state.copy(files: {...state.files, id: path}, progress: {...state.progress}..remove(id));
    for (final twin in _waiting.remove(id) ?? const <Song>[]) {
      await _alias(twin, path);
    }
  }

  /// Gives up on a song (gone from the server, or it sent something that isn't audio).
  Future<void> _drop(_Queued q) async {
    final id = q.song.id;
    _queue.remove(id);
    _saveQueue();
    _inFlight[_recording(q.song)]?.removeWhere((e) => e.$2 == id);
    state = state.copy(progress: {...state.progress}..remove(id));
    await _deletePart(id);
    final twins = _waiting.remove(id);
    if (twins != null && twins.isNotEmpty) await download(twins); // that copy failed: try the others
  }

  Future<void> _deletePart(String id) async {
    try {
      await for (final f in (await musicDir()).list()) {
        final name = p.basename(f.path);
        if (name.startsWith('$id.') && name.endsWith('.part')) await f.delete();
      }
    } catch (_) {}
  }

  /// Songs Encore 1.7 and older left with Android's download jobs (still queued, or failed while the server
  /// was away) move to the queue above, so they're not forgotten. Called once FileDownloader has started.
  Future<void> adoptOldDownloads() async {
    try {
      final ids = <String>{};
      final tasks = <String>[];
      for (final t in await FileDownloader().allTasks()) {
        if (t.taskId.startsWith('song-')) tasks.add(t.taskId);
      }
      if (tasks.isNotEmpty) await FileDownloader().cancelTasksWithIds(tasks);
      for (final r in await FileDownloader().database.allRecords()) {
        if (!r.taskId.startsWith('song-')) continue;
        if (r.status != TaskStatus.complete) ids.add(r.task.metaData);
        await FileDownloader().database.deleteRecordWithId(r.taskId);
      }
      for (final t in tasks) {
        ids.add(t.substring(5));
      }
      ids.removeWhere((id) => id.isEmpty || has(id) || _queue.containsKey(id));
      if (ids.isEmpty) return;
      final songs = await ref.read(dbProvider).songsByIds(ids.toList());
      await download(songs);
    } catch (_) {}
  }

  Future<void> _onUpdate(TaskUpdate u) async {
    try {
      await _handleUpdate(u);
    } catch (_) {} // e.g. a download that finished while the app was closed, and the server is offline now
  }

  /// Android's download jobs: making songs smaller, and songs an older Encore finished while it was closed.
  Future<void> _handleUpdate(TaskUpdate u) async {
    final id = u.task.metaData;
    if (id.isEmpty || u is! TaskStatusUpdate) return;
    if (id.startsWith('shrink:')) {
      if (u.status.isFinalState) await _shrinkDone(id.substring(7), u);
      return;
    }
    if (u.status != TaskStatus.complete || has(id)) return;
    final path = await u.task.filePath();
    if (!await _isAudio(path)) {
      try {
        await File(path).delete();
      } catch (_) {}
      return;
    }
    final song = (await ref.read(dbProvider).songsByIds([id])).firstOrNull ?? await ref.read(clientProvider)?.song(id);
    if (song == null) return;
    await ref.read(dbProvider).addDownload(song, path, await File(path).length());
    _addCopy(song, path);
    final q = _queue.remove(id);
    if (q != null) {
      _cancel.add(id);
      _saveQueue();
    }
    state = state.copy(files: {...state.files, id: path}, progress: {...state.progress}..remove(id));
  }

  // ── Smaller downloads (like Spotify's download quality) ──
  /// Set by the player: is this song queued to play from its file right now? (then its old file is
  /// deleted on the next start instead of under the player)
  static bool Function(String songId)? fileInUse;

  /// Bytes a song takes at [kbps].
  static int sizeAt(Song s, int kbps) => (s.duration ?? 240) * kbps * 125;

  /// Downloaded files bigger than the download quality would make them: (songs sharing the file, path, bytes).
  Future<List<(List<Song>, String, int)>> oversized() async {
    final set = ref.read(settingsProvider);
    if (set.downloadFormat == 'raw') return const [];
    final byPath = <String, List<Song>>{};
    for (final (song, path, _) in await ref.read(dbProvider).downloads()) {
      if (isPodcastId(song.id)) continue; // episodes stay as the show published them
      (byPath[path] ??= []).add(song);
    }
    final out = <(List<Song>, String, int)>[];
    for (final e in byPath.entries) {
      final st = File(e.key).statSync();
      if (st.type == FileSystemEntityType.notFound) continue;
      if (st.size > sizeAt(e.value.first, set.downloadBitrate) * 1.3 + 65536) out.add((e.value, e.key, st.size));
    }
    return out;
  }

  /// (done, total) while shrinking; null otherwise.
  final shrinking = ValueNotifier<(int, int)?>(null);

  /// Re-downloads [files] at the download quality. Each old file stays until its smaller copy has arrived.
  Future<void> shrink(List<(List<Song>, String, int)> files) async {
    final c = ref.read(clientProvider);
    final set = ref.read(settingsProvider);
    if (c == null || files.isEmpty || set.downloadFormat == 'raw') return;
    shrinking.value = (0, files.length);
    for (final (songs, oldPath, _) in files) {
      final s = songs.first;
      final task = DownloadTask(
        taskId: 'shrink-${s.id}',
        url: c.streamUrl(s.id, format: set.downloadFormat, maxBitRate: set.downloadBitrate).toString(),
        filename: '${s.id}-${set.downloadBitrate}.${set.downloadFormat}',
        directory: 'music',
        baseDirectory: BaseDirectory.applicationSupport,
        updates: Updates.status,
        requiresWiFi: set.downloadWifiOnly,
        retries: 4,
        metaData: 'shrink:${s.id}',
        displayName: 'Making smaller: ${s.artist} - ${s.title}',
      );
      _shrinkOld[s.id] = (songs, oldPath);
      await FileDownloader().enqueue(task);
    }
  }

  final _shrinkOld = <String, (List<Song>, String)>{};

  Future<void> _shrinkDone(String id, TaskStatusUpdate u) async {
    final job = _shrinkOld.remove(id);
    final p = shrinking.value;
    if (p != null) shrinking.value = p.$1 + 1 >= p.$2 ? null : (p.$1 + 1, p.$2);
    if (u.status != TaskStatus.complete) return; // the old file stays
    final newPath = await u.task.filePath();
    if (job == null || !await _isAudio(newPath)) {
      try {
        await File(newPath).delete();
      } catch (_) {}
      return;
    }
    final (songs, oldPath) = job;
    final size = await File(newPath).length();
    final db = ref.read(dbProvider);
    final files = {...state.files};
    for (final e in state.files.entries.where((e) => e.value == oldPath).toList()) {
      final song = songs.where((x) => x.id == e.key).firstOrNull ?? songs.first;
      await db.addDownload(song, newPath, e.key == songs.first.id ? size : 0);
      files[e.key] = newPath;
    }
    for (final l in _copies.values) {
      for (var i = 0; i < l.length; i++) {
        if (l[i].$2 == oldPath) l[i] = (l[i].$1, newPath);
      }
    }
    state = state.copy(files: files);
    final busy = files.entries.any((e) => e.value == newPath && (fileInUse?.call(e.key) ?? false));
    if (busy) {
      await prefs.setStringList('deleteLater', [...?prefs.getStringList('deleteLater'), oldPath]);
    } else {
      try {
        await File(oldPath).delete();
      } catch (_) {}
    }
  }

  /// Episodes you finished more than a week ago don't stay on the phone (your place and "played" do).
  Future<void> cleanPlayedEpisodes() async {
    final done = (jsonDecode(prefs.getString('podcastDone') ?? '{}') as Map).cast<String, dynamic>();
    final week = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    final old = [
      for (final e in done.entries)
        if ((e.value as num) < week && state.files.containsKey(e.key)) e.key,
    ];
    if (old.isNotEmpty) await remove(old);
    done.removeWhere((k, v) => (v as num) < week);
    await prefs.setString('podcastDone', jsonEncode(done));
  }

  Future<void> remove(Iterable<String> ids) async {
    final files = {...state.files};
    final gone = <String>{};
    final progress = {...state.progress};
    var dequeued = false;
    for (final id in ids) {
      final q = _queue.remove(id); // still on its way: called off, and its partial file goes
      if (q != null) {
        dequeued = true;
        progress.remove(id);
        _inFlight[_recording(q.song)]?.removeWhere((e) => e.$2 == id);
        if (_running.contains(id)) {
          _cancel.add(id);
        } else {
          await _deletePart(id);
        }
      }
      final path = files.remove(id);
      await ref.read(dbProvider).removeDownload(id);
      if (path != null && !files.containsValue(path)) gone.add(path); // no other copy uses the file
    }
    for (final path in gone) {
      try {
        await File(path).delete();
      } catch (_) {}
      for (final l in _copies.values) {
        l.removeWhere((e) => e.$2 == path);
      }
    }
    final manual = (prefs.getStringList('manualDownloads') ?? const <String>[]).toSet()..removeAll(ids);
    prefs.setStringList('manualDownloads', manual.toList());
    if (dequeued) _saveQueue();
    state = state.copy(files: files, progress: progress);
  }

  // ── Collections kept downloaded (like Spotify's download switch) ──
  bool isPinned(String key) => state.pins.contains(key);

  void _savePins(Set<String> pins) {
    prefs.setStringList('downloadPins', pins.toList());
    state = state.copy(pins: pins);
  }

  Future<void> pin(String key, List<Song> songs) async {
    _savePins({...state.pins, key});
    await download(songs);
  }

  /// Switch a collection off: its songs go, unless another kept collection or a single download needs them.
  Future<void> unpin(String key, List<Song> songs) async {
    _savePins({...state.pins}..remove(key));
    if (state.pins.contains('library')) return;
    final keep = <String>{...prefs.getStringList('manualDownloads') ?? const <String>[]};
    for (final k in state.pins) {
      final l = await _pinSongs(k);
      if (l == null) return; // can't tell what another kept collection needs: delete nothing rather than too much
      keep.addAll(l.map((s) => s.id));
    }
    await remove(songs.map((s) => s.id).where((id) => !keep.contains(id)));
  }

  /// The songs of a kept collection, or null when they can't be looked up right now.
  Future<List<Song>?> _pinSongs(String key) async {
    final repo = ref.read(repoProvider);
    try {
      if (key == 'library') return await ref.read(dbProvider).allSongs();
      if (key == 'starred') return (await repo.starred()).songs;
      if (key.startsWith('album:')) return (await repo.album(key.substring(6))).songs;
      if (key.startsWith('playlist:')) return (await repo.playlist(key.substring(9))).songs;
      return const [];
    } catch (_) {
      return null;
    }
  }

  /// Download what's new in every kept collection (songs added to a playlist, newly hearted songs...).
  Future<void> refreshPins() async {
    if (!ref.read(repoProvider).online) return;
    for (final k in state.pins) {
      final l = await _pinSongs(k);
      if (l != null) await download(l.where((s) => !s.isLookup && !has(s.id)).toList());
    }
  }
}

final downloadsProvider = NotifierProvider<DownloadsNotifier, DownloadsState>(DownloadsNotifier.new);

/// A song waiting to download, and how (kept across restarts in the 'downloadQueue' setting).
class _Queued {
  _Queued(this.song, this.format, this.kbps);
  final Song song;
  final String format; // 'raw' (the original file) or what the server converts to, e.g. 'opus'
  final int kbps;
  int tries = 0;
  DateTime? waitUntil; // failed a moment ago: tried again after this

  Map<String, dynamic> toJson() => {'song': song.toJson(), 'format': format, 'kbps': kbps};
  static _Queued fromJson(Map<String, dynamic> j) => _Queued(
    Song.fromJson((j['song'] as Map).cast<String, dynamic>()),
    '${j['format'] ?? 'raw'}',
    (j['kbps'] as num?)?.toInt() ?? 160,
  );
}
