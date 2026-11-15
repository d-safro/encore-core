import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

class SubsonicException implements Exception {
  final int code;
  final String message;
  SubsonicException(this.code, this.message);
  @override
  String toString() => message;
}

class Credentials {
  final String server, username, password;
  const Credentials(this.server, this.username, this.password);
  String get base => server.trim().replaceAll(RegExp(r'/+$'), '');
}

/// Subsonic / OpenSubsonic API client. Token auth (md5(password + salt)), JSON responses.
class SubsonicClient {
  SubsonicClient(this.creds, {this.clientName = 'Encore', http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final Credentials creds;
  final String clientName;
  final http.Client _http;
  static const apiVersion = '1.16.1';
  final _rnd = Random.secure();

  Map<String, String> _auth({String? client}) {
    final salt = List.generate(12, (_) => _rnd.nextInt(36).toRadixString(36)).join();
    final token = md5.convert(utf8.encode(creds.password + salt)).toString();
    return {'u': creds.username, 't': token, 's': salt, 'v': apiVersion, 'c': client ?? clientName, 'f': 'json'};
  }

  Uri url(String method, [Map<String, dynamic> params = const {}, String? client]) {
    final q = <String, dynamic>{..._auth(client: client)};
    params.forEach((k, v) {
      if (v == null) return;
      q[k] = v is List ? v.map((e) => e.toString()).toList() : v.toString();
    });
    return Uri.parse('${creds.base}/rest/$method').replace(queryParameters: q);
  }

  Future<Map<String, dynamic>> call(String method,
      [Map<String, dynamic> params = const {}, String? client, Duration timeout = const Duration(seconds: 30)]) async {
    final res = await _http.get(url(method, params, client)).timeout(timeout);
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw SubsonicException(40, 'Wrong username or password');
    }
    if (res.statusCode != 200) throw SubsonicException(0, 'Server answered ${res.statusCode}');
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final r = (body['subsonic-response'] as Map).cast<String, dynamic>();
    if (r['status'] != 'ok') {
      final e = (r['error'] as Map?)?.cast<String, dynamic>() ?? {};
      throw SubsonicException((e['code'] as num?)?.toInt() ?? 0, (e['message'] ?? 'Request failed').toString());
    }
    return r;
  }

  Map<String, dynamic> _m(dynamic v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
  List<Map<String, dynamic>> _l(dynamic v) =>
      v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : const [];

  // ── System ──
  Future<Map<String, dynamic>> ping() => call('ping', const {}, null, const Duration(seconds: 15));

  Future<Set<String>> openSubsonicExtensions() async {
    try {
      final r = await call('getOpenSubsonicExtensions');
      return _l(r['openSubsonicExtensions']).map((e) => e['name'].toString()).toSet();
    } catch (_) {
      return {};
    }
  }

  // ── Browsing ──
  Future<List<Album>> albumList(String type,
      {int size = 50, int offset = 0, int? fromYear, int? toYear, String? genre, String? client}) async {
    final r = await call('getAlbumList2', {
      'type': type,
      'size': size,
      'offset': offset,
      'fromYear': fromYear,
      'toYear': toYear,
      'genre': genre,
    }, client);
    return _l(_m(r['albumList2'])['album']).map(Album.fromJson).toList();
  }

  Future<Album> album(String id) async => Album.fromJson(_m((await call('getAlbum', {'id': id}))['album']));

  Future<List<Artist>> artists() async {
    final r = await call('getArtists');
    return _l(_m(r['artists'])['index']).expand((i) => _l(i['artist'])).map(Artist.fromJson).toList();
  }

  Future<Artist> artist(String id) async => Artist.fromJson(_m((await call('getArtist', {'id': id}))['artist']));

  Future<ArtistInfo> artistInfo(String id) async {
    try {
      return ArtistInfo.fromJson(_m((await call('getArtistInfo2', {'id': id, 'count': 12}))['artistInfo2']));
    } catch (_) {
      return const ArtistInfo();
    }
  }

  Future<List<Song>> topSongs(String artistName, {int count = 20}) async {
    try {
      final r = await call('getTopSongs', {'artist': artistName, 'count': count});
      return _l(_m(r['topSongs'])['song']).map(Song.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Song> song(String id) async => Song.fromJson(_m((await call('getSong', {'id': id}))['song']));

  Future<List<Genre>> genres() async =>
      _l(_m((await call('getGenres'))['genres'])['genre']).map(Genre.fromJson).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Future<List<Song>> songsByGenre(String genre, {int count = 200, int offset = 0}) async =>
      _l(_m((await call('getSongsByGenre', {'genre': genre, 'count': count, 'offset': offset}))['songsByGenre'])['song'])
          .map(Song.fromJson)
          .toList();

  Future<List<Song>> randomSongs({int size = 50, String? genre, int? fromYear, int? toYear}) async =>
      _l(_m((await call('getRandomSongs', {'size': size, 'genre': genre, 'fromYear': fromYear, 'toYear': toYear}))[
              'randomSongs'])['song'])
          .map(Song.fromJson)
          .toList();

  Future<SearchResult> starred() async => SearchResult.fromJson(_m((await call('getStarred2'))['starred2']));

  Future<SearchResult> search(String query,
      {int artistCount = 20, int albumCount = 30, int songCount = 50, int offset = 0, String? client}) async {
    final r = await call('search3', {
      'query': query,
      'artistCount': artistCount,
      'albumCount': albumCount,
      'songCount': songCount,
      'songOffset': offset,
      'albumOffset': offset,
      'artistOffset': offset,
    }, client);
    return SearchResult.fromJson(_m(r['searchResult3']));
  }

  Future<List<MusicFolder>> musicFolders() async => _l(_m((await call('getMusicFolders'))['musicFolders'])['musicFolder'])
      .map((f) => MusicFolder(f['id'].toString(), (f['name'] ?? '').toString()))
      .toList();

  Future<List<DirEntry>> indexes({String? folderId}) async {
    final r = _m((await call('getIndexes', {'musicFolderId': folderId}))['indexes']);
    return _l(r['index'])
        .expand((i) => _l(i['artist']))
        .map((a) => DirEntry(id: a['id'].toString(), name: (a['name'] ?? '').toString()))
        .toList();
  }

  Future<List<DirEntry>> directory(String id) async {
    final r = _m((await call('getMusicDirectory', {'id': id}))['directory']);
    return _l(r['child']).map((c) {
      final dir = c['isDir'] == true;
      return DirEntry(
          id: c['id'].toString(),
          name: (c['title'] ?? c['name'] ?? '').toString(),
          coverArt: (c['coverArt'] ?? '').toString(),
          isDir: dir,
          song: dir ? null : Song.fromJson(c));
    }).toList();
  }

  // ── Playlists ──
  Future<List<Playlist>> playlists() async =>
      _l(_m((await call('getPlaylists'))['playlists'])['playlist']).map(Playlist.fromJson).toList();

  Future<Playlist> playlist(String id) async => Playlist.fromJson(_m((await call('getPlaylist', {'id': id}))['playlist']));

  Future<Playlist> createPlaylist(String name, List<String> songIds) async =>
      Playlist.fromJson(_m((await call('createPlaylist', {'name': name, 'songId': songIds}))['playlist']));

  /// Replaces the songs of a playlist (createPlaylist with playlistId overwrites).
  Future<void> setPlaylistSongs(String id, List<String> songIds) =>
      call('createPlaylist', {'playlistId': id, 'songId': songIds});

  Future<void> updatePlaylist(String id,
          {String? name, String? comment, bool? public, List<String>? add, List<int>? removeIndexes}) =>
      call('updatePlaylist', {
        'playlistId': id,
        'name': name,
        'comment': comment,
        'public': public,
        'songIdToAdd': add,
        'songIndexToRemove': removeIndexes,
      });

  Future<void> deletePlaylist(String id) => call('deletePlaylist', {'id': id});

  // ── Annotation ──
  Future<void> star({String? id, String? albumId, String? artistId}) =>
      call('star', {'id': id, 'albumId': albumId, 'artistId': artistId});
  Future<void> unstar({String? id, String? albumId, String? artistId}) =>
      call('unstar', {'id': id, 'albumId': albumId, 'artistId': artistId});
  Future<void> setRating(String id, int rating) => call('setRating', {'id': id, 'rating': rating});
  Future<void> scrobble(String id, {required bool submission, DateTime? time}) => call('scrobble', {
        'id': id,
        'submission': submission,
        if (time != null) 'time': time.millisecondsSinceEpoch,
      });

  // ── Play queue (follows you between devices and Feishin) ──
  Future<(List<Song>, String?, int)> playQueue() async {
    final r = _m((await call('getPlayQueue'))['playQueue']);
    return (
      _l(r['entry']).map(Song.fromJson).toList(),
      r['current']?.toString(),
      (r['position'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> savePlayQueue(List<String> ids, {String? current, int positionMs = 0}) =>
      call('savePlayQueue', {'id': ids, 'current': current, 'position': positionMs});

  // ── Lyrics ──
  Future<Lyrics> lyrics(Song s) async {
    try {
      final r = await call('getLyricsBySongId', {'id': s.id});
      final list = _l(_m(r['lyricsList'])['structuredLyrics']);
      if (list.isNotEmpty) {
        final synced = list.where((l) => l['synced'] == true);
        return Lyrics.fromStructured(synced.isNotEmpty ? synced.first : list.first);
      }
    } catch (_) {}
    try {
      final r = await call('getLyrics', {'artist': s.artist, 'title': s.title});
      final text = (_m(r['lyrics'])['value'] ?? '').toString();
      if (text.trim().isNotEmpty) return Lyrics.plain(text);
    } catch (_) {}
    return const Lyrics();
  }

  // ── Mixes ──
  /// Sound-alike songs (AudioMuse on the server), falling back to Last.fm-style similar songs.
  Future<List<Song>> similarSongs(String id, {int count = 50}) async {
    try {
      final r = await call('getSonicSimilarTracks', {'id': id, 'count': count});
      final songs = _l(_m(r['sonicMatches'] ?? r['similarSongs'])['song'] ?? r['sonicMatches'])
          .map((e) => Song.fromJson(e['entry'] is Map ? (e['entry'] as Map).cast<String, dynamic>() : e))
          .toList();
      if (songs.isNotEmpty) return songs;
    } catch (_) {}
    try {
      final r = await call('getSimilarSongs2', {'id': id, 'count': count});
      return _l(_m(r['similarSongs2'])['song']).map(Song.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }

  /// A path of songs that moves from one sound to another (AudioMuse "bridge").
  Future<List<Song>> sonicPath(String fromId, String toId, {int count = 25}) async {
    try {
      final r = await call('findSonicPath', {'startSongId': fromId, 'endSongId': toId, 'count': count});
      return _l(_m(r['sonicPath'] ?? r['sonicMatches'])['song'] ?? r['sonicPath'])
          .map((e) => Song.fromJson(e['entry'] is Map ? (e['entry'] as Map).cast<String, dynamic>() : e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // ── Radio ──
  Future<List<InternetRadio>> radios() async {
    try {
      return _l(_m((await call('getInternetRadioStations'))['internetRadioStations'])['internetRadioStation'])
          .map(InternetRadio.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // ── Media URLs ──
  Uri streamUrl(String id, {String? format, int? maxBitRate}) => url('stream', {
        'id': id,
        if (format != null && format != 'raw') 'format': format,
        if (maxBitRate != null && maxBitRate > 0) 'maxBitRate': maxBitRate,
      });

  Uri downloadUrl(String id) => url('download', {'id': id});

  Uri coverUrl(String coverArt, {int size = 600}) => url('getCoverArt', {'id': coverArt, 'size': size});

  void close() => _http.close();
}
