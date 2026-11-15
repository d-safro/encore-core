// Data models for the Subsonic / OpenSubsonic API (as served by Navidrome and music-lookup).

/// Songs, albums and artists that music-lookup offers but that aren't in the library yet have ids
/// starting with "dz-" and a ⬇ / ⏳ / ✕ mark at the start of their title.
enum LookupState { none, available, downloading, failed }

LookupState _lookupFromTitle(String id, String title) {
  if (!id.startsWith('dz-')) return LookupState.none;
  if (title.startsWith('⏳')) return LookupState.downloading;
  if (title.startsWith('✕')) return LookupState.failed;
  return LookupState.available;
}

String _stripMark(String title) => title.replaceFirst(RegExp(r'^[⬇⏳✕]\s*'), '');

int? _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) : null));
double? _dbl(dynamic v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
String _str(dynamic v) => v == null ? '' : v.toString();
List<Map<String, dynamic>> _list(dynamic v) =>
    v is List ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList() : const [];

class ReplayGain {
  final double? trackGain, albumGain, trackPeak, albumPeak;
  const ReplayGain({this.trackGain, this.albumGain, this.trackPeak, this.albumPeak});
  factory ReplayGain.fromJson(Map<String, dynamic>? j) => j == null
      ? const ReplayGain()
      : ReplayGain(
          trackGain: _dbl(j['trackGain']),
          albumGain: _dbl(j['albumGain']),
          trackPeak: _dbl(j['trackPeak']),
          albumPeak: _dbl(j['albumPeak']),
        );
  Map<String, dynamic> toJson() => {
    'trackGain': trackGain,
    'albumGain': albumGain,
    'trackPeak': trackPeak,
    'albumPeak': albumPeak,
  };
}

class Song {
  final String id, title, album, albumId, artist, artistId, genre, coverArt, suffix, contentType, path;
  final String isrc; // recording code, for finding the song on other services (share links)
  final int? track, disc, year, duration, bitRate, size, userRating, playCount;
  final bool starred;
  final ReplayGain replayGain;
  final LookupState lookup;
  final DateTime? played;

  const Song({
    required this.id,
    required this.title,
    this.album = '',
    this.albumId = '',
    this.artist = '',
    this.artistId = '',
    this.genre = '',
    this.coverArt = '',
    this.suffix = '',
    this.contentType = '',
    this.path = '',
    this.isrc = '',
    this.track,
    this.disc,
    this.year,
    this.duration,
    this.bitRate,
    this.size,
    this.userRating,
    this.playCount,
    this.starred = false,
    this.replayGain = const ReplayGain(),
    this.lookup = LookupState.none,
    this.played,
  });

  bool get isLookup => lookup != LookupState.none;

  factory Song.fromJson(Map<String, dynamic> j) {
    final id = _str(j['id']);
    final raw = _str(j['title']);
    return Song(
      id: id,
      title: _stripMark(raw),
      album: _str(j['album']),
      albumId: _str(j['albumId']),
      artist: _str(j['artist']),
      artistId: _str(j['artistId']),
      genre: _str(j['genre']),
      coverArt: _str(j['coverArt']),
      suffix: _str(j['suffix']),
      contentType: _str(j['contentType']),
      path: _str(j['path']),
      isrc: j['isrc'] is List ? ((j['isrc'] as List).isEmpty ? '' : _str((j['isrc'] as List).first)) : _str(j['isrc']),
      track: _int(j['track']),
      disc: _int(j['discNumber']),
      year: _int(j['year']),
      duration: _int(j['duration']),
      bitRate: _int(j['bitRate']),
      size: _int(j['size']),
      userRating: _int(j['userRating']),
      playCount: _int(j['playCount']),
      starred: j['starred'] != null,
      replayGain: ReplayGain.fromJson((j['replayGain'] as Map?)?.cast<String, dynamic>()),
      lookup: _lookupFromTitle(id, raw),
      played: j['played'] != null ? DateTime.tryParse(_str(j['played'])) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'album': album,
    'albumId': albumId,
    'artist': artist,
    'artistId': artistId,
    'genre': genre,
    'coverArt': coverArt,
    'suffix': suffix,
    'contentType': contentType,
    'path': path,
    if (isrc.isNotEmpty) 'isrc': isrc,
    'track': track,
    'discNumber': disc,
    'year': year,
    'duration': duration,
    'bitRate': bitRate,
    'size': size,
    'userRating': userRating,
    'playCount': playCount,
    if (starred) 'starred': '1',
    'replayGain': replayGain.toJson(),
  };

  Song copyWith({bool? starred, int? userRating}) => Song(
    id: id,
    title: title,
    album: album,
    albumId: albumId,
    artist: artist,
    artistId: artistId,
    genre: genre,
    coverArt: coverArt,
    suffix: suffix,
    contentType: contentType,
    path: path,
    isrc: isrc,
    track: track,
    disc: disc,
    year: year,
    duration: duration,
    bitRate: bitRate,
    size: size,
    userRating: userRating ?? this.userRating,
    playCount: playCount,
    starred: starred ?? this.starred,
    replayGain: replayGain,
    lookup: lookup,
    played: played,
  );
}

class Album {
  final String id, name, artist, artistId, coverArt, genre;
  final int? year, songCount, duration, playCount, userRating;
  final bool starred;
  final LookupState lookup;
  final List<Song> songs;
  final DateTime? created;

  const Album({
    required this.id,
    required this.name,
    this.artist = '',
    this.artistId = '',
    this.coverArt = '',
    this.genre = '',
    this.year,
    this.songCount,
    this.duration,
    this.playCount,
    this.userRating,
    this.starred = false,
    this.lookup = LookupState.none,
    this.songs = const [],
    this.created,
  });

  bool get isLookup => lookup != LookupState.none;

  factory Album.fromJson(Map<String, dynamic> j) {
    final id = _str(j['id']);
    final raw = _str(j['name'] ?? j['title']);
    return Album(
      id: id,
      name: _stripMark(raw),
      artist: _str(j['artist']),
      artistId: _str(j['artistId']),
      coverArt: _str(j['coverArt']),
      genre: _str(j['genre']),
      year: _int(j['year']),
      songCount: _int(j['songCount']),
      duration: _int(j['duration']),
      playCount: _int(j['playCount']),
      userRating: _int(j['userRating']),
      starred: j['starred'] != null,
      lookup: _lookupFromTitle(id, raw),
      songs: _list(j['song']).map(Song.fromJson).toList(),
      created: j['created'] != null ? DateTime.tryParse(_str(j['created'])) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'artist': artist,
    'artistId': artistId,
    'coverArt': coverArt,
    'genre': genre,
    'year': year,
    'songCount': songCount,
    'duration': duration,
    'playCount': playCount,
    'userRating': userRating,
    if (starred) 'starred': '1',
    if (created != null) 'created': created!.toIso8601String(),
  };
}

class Artist {
  final String id, name, coverArt;
  final int? albumCount;
  final bool starred;
  final LookupState lookup;
  final List<Album> albums;

  bool get isLookup => lookup != LookupState.none;

  const Artist({
    required this.id,
    required this.name,
    this.coverArt = '',
    this.albumCount,
    this.starred = false,
    this.lookup = LookupState.none,
    this.albums = const [],
  });

  factory Artist.fromJson(Map<String, dynamic> j) {
    final id = _str(j['id']);
    final raw = _str(j['name']);
    return Artist(
      id: id,
      name: _stripMark(raw),
      coverArt: _str(j['coverArt']),
      albumCount: _int(j['albumCount']),
      starred: j['starred'] != null,
      lookup: _lookupFromTitle(id, raw),
      albums: _list(j['album']).map(Album.fromJson).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'coverArt': coverArt,
    'albumCount': albumCount,
    if (starred) 'starred': '1',
  };
}

class ArtistInfo {
  final String biography, imageUrl, lastFmUrl;
  final List<Artist> similar;
  const ArtistInfo({this.biography = '', this.imageUrl = '', this.lastFmUrl = '', this.similar = const []});
  factory ArtistInfo.fromJson(Map<String, dynamic> j) => ArtistInfo(
    biography: _str(j['biography']).replaceAll(RegExp(r'<[^>]+>'), '').trim(),
    imageUrl: _str(j['largeImageUrl'] ?? j['mediumImageUrl']),
    lastFmUrl: _str(j['lastFmUrl']),
    similar: _list(j['similarArtist']).map(Artist.fromJson).toList(),
  );
}

class Playlist {
  final String id, name, comment, owner, coverArt;
  final int? songCount, duration;
  final bool public;
  final List<Song> songs;
  final DateTime? changed;

  const Playlist({
    required this.id,
    required this.name,
    this.comment = '',
    this.owner = '',
    this.coverArt = '',
    this.songCount,
    this.duration,
    this.public = false,
    this.songs = const [],
    this.changed,
  });

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
    id: _str(j['id']),
    name: _str(j['name']),
    comment: _str(j['comment']),
    owner: _str(j['owner']),
    coverArt: _str(j['coverArt']),
    songCount: _int(j['songCount']),
    duration: _int(j['duration']),
    public: j['public'] == true,
    songs: _list(j['entry']).map(Song.fromJson).toList(),
    changed: j['changed'] != null ? DateTime.tryParse(_str(j['changed'])) : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'comment': comment,
    'owner': owner,
    'coverArt': coverArt,
    'songCount': songCount,
    'duration': duration,
    'public': public,
  };
}

class Genre {
  final String name;
  final int songCount, albumCount;
  const Genre(this.name, this.songCount, this.albumCount);
  factory Genre.fromJson(Map<String, dynamic> j) =>
      Genre(_str(j['value'] ?? j['name']), _int(j['songCount']) ?? 0, _int(j['albumCount']) ?? 0);
}

class LyricLine {
  final Duration? start;
  final String text;
  const LyricLine(this.start, this.text);
}

class Lyrics {
  final bool synced;
  final List<LyricLine> lines;
  final String lang;
  final String source; // where they came from when not your server ("LRCLIB", "NetEase", ...)
  const Lyrics({this.synced = false, this.lines = const [], this.lang = '', this.source = ''});
  bool get isEmpty => lines.isEmpty;
  Lyrics withSource(String s) => Lyrics(synced: synced, lines: lines, lang: lang, source: s);

  factory Lyrics.fromStructured(Map<String, dynamic> j) {
    final synced = j['synced'] == true;
    final offset = _int(j['offset']) ?? 0;
    return Lyrics(
      synced: synced,
      lang: _str(j['lang']),
      lines: _list(j['line'])
          .map(
            (l) => LyricLine(
              synced && l['start'] != null ? Duration(milliseconds: (_int(l['start']) ?? 0) + offset) : null,
              _str(l['value']),
            ),
          )
          .toList(),
    );
  }

  factory Lyrics.plain(String text) =>
      Lyrics(lines: text.split('\n').map((l) => LyricLine(null, l.trimRight())).toList());
}

class SearchResult {
  final List<Artist> artists;
  final List<Album> albums;
  final List<Song> songs;
  const SearchResult({this.artists = const [], this.albums = const [], this.songs = const []});
  bool get isEmpty => artists.isEmpty && albums.isEmpty && songs.isEmpty;
  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
    artists: _list(j['artist']).map(Artist.fromJson).toList(),
    albums: _list(j['album']).map(Album.fromJson).toList(),
    songs: _list(j['song']).map(Song.fromJson).toList(),
  );
}

class MusicFolder {
  final String id, name;
  const MusicFolder(this.id, this.name);
}

/// A folder in "browse by folder" (getIndexes / getMusicDirectory).
class DirEntry {
  final String id, name, coverArt;
  final bool isDir;
  final Song? song;
  const DirEntry({required this.id, required this.name, this.coverArt = '', this.isDir = true, this.song});
}

class InternetRadio {
  final String id, name, streamUrl, homePageUrl;
  const InternetRadio(this.id, this.name, this.streamUrl, this.homePageUrl);
  factory InternetRadio.fromJson(Map<String, dynamic> j) =>
      InternetRadio(_str(j['id']), _str(j['name']), _str(j['streamUrl']), _str(j['homePageUrl'] ?? j['homepageUrl']));
}

String formatDuration(int? seconds) {
  if (seconds == null) return '';
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}

/// A podcast show you follow (served by music-lookup's podcast support).
class PodcastChannel {
  final String id, url, title, author, description, coverArt, error;
  final int unplayed, episodeCount;
  final DateTime? latest;
  final List<PodcastEpisode> episodes;
  const PodcastChannel({
    required this.id,
    this.url = '',
    this.title = '',
    this.author = '',
    this.description = '',
    this.coverArt = '',
    this.error = '',
    this.unplayed = 0,
    this.episodeCount = 0,
    this.latest,
    this.episodes = const [],
  });
  factory PodcastChannel.fromJson(Map<String, dynamic> j) {
    final eps = _list(j['episode']).map(PodcastEpisode.fromJson).toList();
    final latest = _int(j['latest']);
    return PodcastChannel(
      id: _str(j['id']),
      url: _str(j['url']),
      title: _str(j['title']),
      author: _str(j['author']),
      description: _str(j['description']),
      coverArt: _str(j['coverArt']),
      error: _str(j['errorMessage']),
      unplayed: _int(j['unplayed']) ?? eps.where((e) => !e.played).length,
      episodeCount: _int(j['episodeCount']) ?? eps.length,
      latest: latest != null && latest > 0 ? DateTime.fromMillisecondsSinceEpoch(latest * 1000) : null,
      episodes: eps,
    );
  }
}

class PodcastEpisode {
  final String id, channelId, title, show, author, description, coverArt, suffix;
  final DateTime? published;
  final int duration, position; // seconds / milliseconds
  final bool downloaded, played; // downloaded = on the server's drive
  const PodcastEpisode({
    required this.id,
    this.channelId = '',
    this.title = '',
    this.show = '',
    this.author = '',
    this.description = '',
    this.coverArt = '',
    this.suffix = 'mp3',
    this.published,
    this.duration = 0,
    this.position = 0,
    this.downloaded = false,
    this.played = false,
  });
  factory PodcastEpisode.fromJson(Map<String, dynamic> j) => PodcastEpisode(
    id: _str(j['id']),
    channelId: _str(j['channelId']),
    title: _str(j['title']),
    show: _str(j['album']),
    author: _str(j['artist']),
    description: _str(j['description']),
    coverArt: _str(j['coverArt']),
    suffix: _str(j['suffix']).isEmpty ? 'mp3' : _str(j['suffix']),
    published: DateTime.tryParse(_str(j['publishDate'])),
    duration: _int(j['duration']) ?? 0,
    position: _int(j['position']) ?? 0,
    downloaded: j['downloaded'] == true,
    played: j['played'] == true,
  );

  /// Started and not finished: worth resuming.
  bool get inProgress => !played && position > 15000 && (duration == 0 || position < duration * 1000 - 30000);

  /// As a playable item for the player and downloads.
  Song toSong() => Song(
    id: id,
    title: title,
    artist: show,
    album: show,
    albumId: channelId,
    coverArt: coverArt,
    duration: duration > 0 ? duration : null,
    suffix: suffix,
    contentType: 'audio/mpeg',
  );
}

/// Podcast episode ids start with "pe-", shows with "pc-".
bool isPodcastId(String id) => id.startsWith('pe-');
