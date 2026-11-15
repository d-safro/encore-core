import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'account.dart';
import 'db.dart';
import 'models.dart';
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

/// Offline = switched to offline mode in settings, or no network at all.
final offlineProvider = Provider<bool>((ref) {
  if (ref.watch(settingsProvider.select((s) => s.offlineMode))) return true;
  final r = ref.watch(connectivityProvider).value;
  return r != null && (r.isEmpty || r.every((e) => e == ConnectivityResult.none));
});

/// Everything the screens read goes through here: the server when online, the local copy otherwise
/// (and as a fallback when the server can't be reached).
class Repo {
  Repo(this.client, this.db, this.offline, this.settings);
  final SubsonicClient? client;
  final LibraryDb db;
  final bool offline;
  final Settings settings;

  bool get online => client != null && !offline;

  Future<T> _either<T>(Future<T> Function(SubsonicClient c) remote, Future<T> Function() local) async {
    if (!online) return local();
    try {
      return await remote(client!);
    } on SocketException {
      return local();
    } on TimeoutException {
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
      (c) => c.albumList(genre != null ? 'byGenre' : type, size: size, offset: offset, genre: genre)
          .then((l) => settings.showLookup ? l : l.where((a) => !a.isLookup).toList()),
      () => type == 'starred'
          ? db.albums().then((l) => l.where((a) => a.starred).toList())
          : db.albums(orderBy: _orderFor(type), limit: size, offset: offset, genre: genre));

  Future<Album> album(String id) => _either((c) async {
        final a = await c.album(id);
        if (settings.showLookup) return a;
        return Album(
            id: a.id, name: a.name, artist: a.artist, artistId: a.artistId, coverArt: a.coverArt, genre: a.genre,
            year: a.year, songCount: a.songCount, duration: a.duration, starred: a.starred, created: a.created,
            userRating: a.userRating, songs: a.songs.where((s) => !s.isLookup).toList());
      }, () async => (await db.album(id)) ?? (throw Exception('This album isn\'t saved on the phone')));

  Future<List<Artist>> artists() => _either((c) => c.artists(), db.artists);

  Future<Artist> artist(String id) => _either((c) async {
        final a = await c.artist(id);
        if (settings.showLookup) return a;
        return Artist(id: a.id, name: a.name, coverArt: a.coverArt, starred: a.starred,
            albums: a.albums.where((x) => !x.isLookup).toList());
      }, () async => (await db.artist(id)) ?? (throw Exception('This artist isn\'t saved on the phone')));

  Future<List<Playlist>> playlists() => _either((c) => c.playlists(), db.playlists);

  Future<Playlist> playlist(String id) => _either((c) => c.playlist(id), () async {
        final pl = (await db.playlists()).firstWhere((p) => p.id == id);
        return Playlist(id: pl.id, name: pl.name, comment: pl.comment, songs: await db.playlistSongs(id));
      });

  Future<SearchResult> search(String q) => _either((c) => c.search(q), () => db.search(q));

  Future<SearchResult> starred() => _either((c) => c.starred(),
      () async => SearchResult(songs: await db.starredSongs(), albums: (await db.albums()).where((a) => a.starred).toList()));

  Future<List<Genre>> genres() => _either((c) => c.genres(), () async {
        final albums = await db.albums();
        final m = <String, int>{};
        for (final a in albums) {
          if (a.genre.isNotEmpty) m[a.genre] = (m[a.genre] ?? 0) + 1;
        }
        return m.entries.map((e) => Genre(e.key, 0, e.value)).toList()..sort((a, b) => a.name.compareTo(b.name));
      });

  Future<List<Song>> songsByGenre(String g) => _either((c) => c.songsByGenre(g), () => db.songsByGenre(g));

  Future<List<Song>> randomSongs({int size = 50, String? genre}) => _either(
      (c) => c.randomSongs(size: size, genre: genre),
      () async => (await db.allSongs())..shuffle()).then((l) => l.take(size).toList());

  Future<List<Song>> allSongs({int size = 200, int offset = 0}) => _either(
      (c) => c.search('', songCount: size, offset: offset, artistCount: 0, albumCount: 0, client: 'Encore-sync')
          .then((r) => r.songs.where((s) => !s.isLookup).toList()),
      () => db.allSongs(limit: size, offset: offset));
}

final repoProvider = Provider<Repo>((ref) => Repo(
      ref.watch(clientProvider),
      ref.watch(dbProvider),
      ref.watch(offlineProvider),
      ref.watch(settingsProvider),
    ));

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
      for (var off = 0;; off += 500) {
        state = SyncState(running: true, message: 'Albums… ${albums.length}');
        final page = await c.albumList('alphabeticalByName', size: 500, offset: off, client: who);
        albums.addAll(page.where((a) => !a.isLookup));
        if (page.length < 500) break;
      }
      final songs = <Song>[];
      for (var off = 0;; off += 500) {
        state = SyncState(running: true, message: 'Songs… ${songs.length}');
        final r = await c.search('', artistCount: 0, albumCount: 0, songCount: 500, offset: off, client: who);
        songs.addAll(r.songs.where((s) => !s.isLookup));
        if (r.songs.length < 500) break;
      }
      state = const SyncState(running: true, message: 'Playlists…');
      final playlists = await c.playlists();
      final plSongs = <String, List<String>>{};
      for (final p in playlists) {
        plSongs[p.id] = (await c.playlist(p.id)).songs.map((s) => s.id).toList();
      }
      await ref.read(dbProvider).replaceLibrary(
          artists: artists, albums: albums, songs: songs, playlists: playlists, playlistSongs: plSongs);
      state = SyncState(message: '${songs.length} songs, ${albums.length} albums saved', last: DateTime.now());
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
  const DownloadsState({this.files = const {}, this.progress = const {}});
}

class DownloadsNotifier extends Notifier<DownloadsState> {
  final _pending = <String, Song>{};
  StreamSubscription? _sub;

  @override
  DownloadsState build() {
    _sub ??= FileDownloader().updates.listen(_onUpdate);
    ref.onDispose(() => _sub?.cancel());
    ref.read(dbProvider).downloadPaths().then((m) => state = DownloadsState(files: m, progress: state.progress));
    return const DownloadsState();
  }

  bool has(String id) => state.files.containsKey(id);

  Future<void> download(List<Song> songs) async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    final s = ref.read(settingsProvider);
    for (final song in songs.where((x) => !x.isLookup && !has(x.id))) {
      final raw = s.downloadFormat == 'raw';
      final url = raw ? c.downloadUrl(song.id) : c.streamUrl(song.id, format: s.downloadFormat, maxBitRate: s.downloadBitrate);
      final ext = raw ? (song.suffix.isEmpty ? 'mp3' : song.suffix) : s.downloadFormat;
      final task = DownloadTask(
        taskId: 'song-${song.id}',
        url: url.toString(),
        filename: '${song.id}.$ext',
        directory: 'music',
        baseDirectory: BaseDirectory.applicationSupport,
        updates: Updates.statusAndProgress,
        requiresWiFi: s.downloadWifiOnly,
        retries: 3,
        metaData: song.id,
        displayName: '${song.artist} - ${song.title}',
      );
      _pending[song.id] = song;
      state = DownloadsState(files: state.files, progress: {...state.progress, song.id: 0});
      await FileDownloader().enqueue(task);
    }
  }

  Future<void> _onUpdate(TaskUpdate u) async {
    final id = u.task.metaData;
    if (u is TaskProgressUpdate) {
      if (u.progress >= 0) state = DownloadsState(files: state.files, progress: {...state.progress, id: u.progress});
    } else if (u is TaskStatusUpdate) {
      if (u.status == TaskStatus.complete) {
        final path = await u.task.filePath();
        final song = _pending.remove(id) ?? await ref.read(clientProvider)?.song(id);
        if (song != null) await ref.read(dbProvider).addDownload(song, path, await File(path).length());
        state = DownloadsState(files: {...state.files, id: path}, progress: {...state.progress}..remove(id));
      } else if (u.status.isFinalState) {
        _pending.remove(id);
        state = DownloadsState(files: state.files, progress: {...state.progress}..remove(id));
      }
    }
  }

  Future<void> remove(Iterable<String> ids) async {
    final files = {...state.files};
    for (final id in ids) {
      final path = files.remove(id);
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      await ref.read(dbProvider).removeDownload(id);
    }
    state = DownloadsState(files: files, progress: state.progress);
  }
}

final downloadsProvider = NotifierProvider<DownloadsNotifier, DownloadsState>(DownloadsNotifier.new);
