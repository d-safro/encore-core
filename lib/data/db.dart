import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Local copy of the library (for offline browsing and search) plus the list of downloaded songs.
class LibraryDb {
  LibraryDb._(this.db);
  final Database db;

  static Future<LibraryDb> open() async {
    final path = p.join(await getDatabasesPath(), 'encore.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        final b = db.batch();
        b.execute(
          'CREATE TABLE songs(id TEXT PRIMARY KEY, json TEXT, album_id TEXT, artist_id TEXT, '
          'title_lc TEXT, artist_lc TEXT, album_lc TEXT, genre TEXT, starred INTEGER, year INTEGER, track INTEGER, disc INTEGER)',
        );
        b.execute('CREATE INDEX songs_album ON songs(album_id)');
        b.execute('CREATE INDEX songs_artist ON songs(artist_id)');
        b.execute(
          'CREATE TABLE albums(id TEXT PRIMARY KEY, json TEXT, artist_id TEXT, name_lc TEXT, artist_lc TEXT, '
          'year INTEGER, created TEXT, genre TEXT, starred INTEGER, play_count INTEGER)',
        );
        b.execute('CREATE TABLE artists(id TEXT PRIMARY KEY, json TEXT, name_lc TEXT, starred INTEGER)');
        b.execute('CREATE TABLE playlists(id TEXT PRIMARY KEY, json TEXT)');
        b.execute('CREATE TABLE playlist_songs(playlist_id TEXT, pos INTEGER, song_id TEXT)');
        b.execute(
          'CREATE TABLE downloads(song_id TEXT PRIMARY KEY, path TEXT, size INTEGER, added INTEGER, json TEXT)',
        );
        b.execute('CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT)');
        await b.commit(noResult: true);
      },
    );
    return LibraryDb._(db);
  }

  // ── Writing (library sync) ──
  Future<void> replaceLibrary({
    required List<Artist> artists,
    required List<Album> albums,
    required List<Song> songs,
    required List<Playlist> playlists,
    required Map<String, List<String>> playlistSongs,
  }) async {
    await db.transaction((tx) async {
      for (final t in ['songs', 'albums', 'artists', 'playlists', 'playlist_songs']) {
        await tx.delete(t);
      }
      final b = tx.batch();
      for (final a in artists) {
        b.insert('artists', {
          'id': a.id,
          'json': jsonEncode(a.toJson()),
          'name_lc': a.name.toLowerCase(),
          'starred': a.starred ? 1 : 0,
        });
      }
      for (final a in albums) {
        b.insert('albums', {
          'id': a.id,
          'json': jsonEncode(a.toJson()),
          'artist_id': a.artistId,
          'name_lc': a.name.toLowerCase(),
          'artist_lc': a.artist.toLowerCase(),
          'year': a.year,
          'created': a.created?.toIso8601String(),
          'genre': a.genre,
          'starred': a.starred ? 1 : 0,
          'play_count': a.playCount ?? 0,
        });
      }
      for (final s in songs) {
        b.insert('songs', _songRow(s));
      }
      for (final pl in playlists) {
        b.insert('playlists', {'id': pl.id, 'json': jsonEncode(pl.toJson())});
        final ids = playlistSongs[pl.id] ?? const [];
        for (var i = 0; i < ids.length; i++) {
          b.insert('playlist_songs', {'playlist_id': pl.id, 'pos': i, 'song_id': ids[i]});
        }
      }
      await b.commit(noResult: true);
      await tx.insert('meta', {
        'key': 'synced',
        'value': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Map<String, Object?> _songRow(Song s) => {
    'id': s.id,
    'json': jsonEncode(s.toJson()),
    'album_id': s.albumId,
    'artist_id': s.artistId,
    'title_lc': s.title.toLowerCase(),
    'artist_lc': s.artist.toLowerCase(),
    'album_lc': s.album.toLowerCase(),
    'genre': s.genre,
    'starred': s.starred ? 1 : 0,
    'year': s.year,
    'track': s.track,
    'disc': s.disc,
  };

  /// Forget the library copy (signing out, or switching to another server). Downloads are kept.
  Future<void> clearLibrary() async {
    await db.transaction((tx) async {
      for (final t in ['songs', 'albums', 'artists', 'playlists', 'playlist_songs', 'meta']) {
        await tx.delete(t);
      }
    });
  }

  Future<void> updateSong(Song s) async {
    await db.update('songs', _songRow(s), where: 'id = ?', whereArgs: [s.id]);
    await db.update('downloads', {'json': jsonEncode(s.toJson())}, where: 'song_id = ?', whereArgs: [s.id]);
  }

  Future<DateTime?> lastSync() async {
    final r = await db.query('meta', where: 'key = ?', whereArgs: ['synced']);
    return r.isEmpty ? null : DateTime.tryParse(r.first['value'] as String);
  }

  // ── Reading ──
  List<Song> _songs(List<Map<String, Object?>> rows) =>
      rows.map((r) => Song.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>)).toList();
  List<Album> _albums(List<Map<String, Object?>> rows) =>
      rows.map((r) => Album.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>)).toList();

  Future<int> songCount() async => Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM songs')) ?? 0;

  Future<List<Song>> allSongs({int limit = 100000, int offset = 0}) async =>
      _songs(await db.query('songs', orderBy: 'artist_lc, album_lc, disc, track', limit: limit, offset: offset));

  Future<List<Album>> albums({String orderBy = 'name_lc', int limit = 100000, int offset = 0, String? genre}) async =>
      _albums(
        await db.query(
          'albums',
          where: genre != null ? 'genre = ?' : null,
          whereArgs: genre != null ? [genre] : null,
          orderBy: orderBy,
          limit: limit,
          offset: offset,
        ),
      );

  Future<List<Artist>> artists() async => (await db.query(
    'artists',
    orderBy: 'name_lc',
  )).map((r) => Artist.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>)).toList();

  Future<Album?> album(String id) async {
    final r = await db.query('albums', where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return null;
    final a = _albums(r).first;
    final songs = _songs(await db.query('songs', where: 'album_id = ?', whereArgs: [id], orderBy: 'disc, track'));
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
      songs: songs,
      created: a.created,
    );
  }

  Future<Artist?> artist(String id) async {
    final r = await db.query('artists', where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return null;
    final a = Artist.fromJson(jsonDecode(r.first['json'] as String) as Map<String, dynamic>);
    final albums = _albums(await db.query('albums', where: 'artist_id = ?', whereArgs: [id], orderBy: 'year'));
    return Artist(
      id: a.id,
      name: a.name,
      coverArt: a.coverArt,
      albumCount: albums.length,
      starred: a.starred,
      albums: albums,
    );
  }

  Future<List<Playlist>> playlists() async =>
      (await db.query('playlists'))
          .map((r) => Playlist.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>))
          .toList();

  Future<List<Song>> playlistSongs(String id) async => _songs(
    await db.rawQuery(
      'SELECT s.json FROM playlist_songs ps JOIN songs s ON s.id = ps.song_id WHERE ps.playlist_id = ? ORDER BY ps.pos',
      [id],
    ),
  );

  Future<List<Song>> songsByIds(List<String> ids) async {
    final out = <Song>[];
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.skip(i).take(500).toList();
      out.addAll(
        _songs(await db.query('songs', where: 'id IN (${List.filled(chunk.length, '?').join(',')})', whereArgs: chunk)),
      );
    }
    return out;
  }

  Future<List<Song>> starredSongs() async =>
      _songs(await db.query('songs', where: 'starred = 1', orderBy: 'artist_lc'));

  Future<List<Song>> songsByGenre(String genre) async =>
      _songs(await db.query('songs', where: 'genre = ?', whereArgs: [genre], orderBy: 'artist_lc, album_lc, track'));

  Future<SearchResult> search(String q) async {
    final like = '%${q.toLowerCase()}%';
    final songs = _songs(
      await db.query(
        'songs',
        where: 'title_lc LIKE ? OR artist_lc LIKE ? OR album_lc LIKE ?',
        whereArgs: [like, like, like],
        limit: 100,
      ),
    );
    final albums = _albums(
      await db.query('albums', where: 'name_lc LIKE ? OR artist_lc LIKE ?', whereArgs: [like, like], limit: 50),
    );
    final artists = (await db.query(
      'artists',
      where: 'name_lc LIKE ?',
      whereArgs: [like],
      limit: 30,
    )).map((r) => Artist.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>)).toList();
    return SearchResult(artists: artists, albums: albums, songs: songs);
  }

  // ── Downloads ──
  Future<void> addDownload(Song s, String path, int size) => db.insert('downloads', {
    'song_id': s.id,
    'path': path,
    'size': size,
    'added': DateTime.now().millisecondsSinceEpoch,
    'json': jsonEncode(s.toJson()),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> removeDownload(String songId) => db.delete('downloads', where: 'song_id = ?', whereArgs: [songId]);

  Future<Map<String, String>> downloadPaths() async => {
    for (final r in await db.query('downloads', columns: ['song_id', 'path']))
      r['song_id'] as String: r['path'] as String,
  };

  Future<List<(Song, String, int)>> downloads() async => (await db.query('downloads', orderBy: 'added DESC'))
      .map(
        (r) => (
          Song.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>),
          r['path'] as String,
          (r['size'] as int?) ?? 0,
        ),
      )
      .toList();
}
