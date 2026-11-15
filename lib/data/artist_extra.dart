import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'library.dart';
import 'models.dart';

/// More about an artist than your library knows, like Spotify's artist page: their popular songs, their whole
/// discography (albums, singles & EPs, compilations) and fans, from Deezer; a short bio from Wikipedia when your
/// server has none. Songs and albums you don't have come back as ⬇ items (music-lookup can fetch them).
/// Only the artist's name is sent.
class ArtistExtra {
  const ArtistExtra({this.fans, this.top = const [], this.albums = const [], this.wiki = '', this.wikiUrl = ''});
  final int? fans;
  final List<Song> top; // most popular first
  final List<(Album, String)> albums; // (album, album | single | ep | compile), newest first
  final String wiki, wikiUrl;
}

const _ua = {'User-Agent': 'Encore music player (https://github.com/d-safro/encore)'};

Future<dynamic> _get(Uri u) async {
  final r = await http.get(u, headers: _ua).timeout(const Duration(seconds: 10));
  if (r.statusCode != 200) return null;
  return jsonDecode(utf8.decode(r.bodyBytes));
}

String normName(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

Future<ArtistExtra> fetchArtistExtra(String name) async {
  int? fans;
  var top = <Song>[];
  final albums = <(Album, String)>[];
  try {
    final found = await _get(Uri.https('api.deezer.com', '/search/artist', {'q': name, 'limit': '5'}));
    final list = found is Map && found['data'] is List ? found['data'] as List : const [];
    final n = normName(name);
    final hit = list.whereType<Map>().where((e) => normName('${e['name']}') == n).firstOrNull;
    if (hit != null) {
      final id = '${hit['id']}';
      fans = (hit['nb_fan'] as num?)?.toInt();
      final results = await Future.wait([
        _get(Uri.https('api.deezer.com', '/artist/$id/top', {'limit': '10'})).catchError((_) => null),
        _get(Uri.https('api.deezer.com', '/artist/$id/albums', {'limit': '100'})).catchError((_) => null),
      ]);
      final t = results[0], a = results[1];
      if (t is Map && t['data'] is List) {
        top = [
          for (final e in (t['data'] as List).whereType<Map>())
            Song.fromJson({
              'id': 'dz-t-${e['id']}',
              'title': '⬇ ${e['title'] ?? ''}',
              'artist': '${(e['artist'] as Map?)?['name'] ?? name}',
              'album': '${(e['album'] as Map?)?['title'] ?? ''}',
              'albumId': 'dz-a-${(e['album'] as Map?)?['id'] ?? ''}',
              'coverArt': 'dz-a-${(e['album'] as Map?)?['id'] ?? ''}',
              'duration': e['duration'],
            }),
        ];
      }
      if (a is Map && a['data'] is List) {
        final seen = <String>{};
        for (final e in (a['data'] as List).whereType<Map>()) {
          final title = '${e['title'] ?? ''}';
          final type = '${e['record_type'] ?? 'album'}';
          if (!seen.add('$type|${normName(title)}')) continue; // the same release twice (clean / explicit)
          albums.add((
            Album.fromJson({
              'id': 'dz-a-${e['id']}',
              'name': '⬇ $title',
              'artist': name,
              'coverArt': 'dz-a-${e['id']}',
              'year': int.tryParse('${e['release_date'] ?? ''}'.split('-').first),
            }),
            type,
          ));
        }
        albums.sort((x, y) => (y.$1.year ?? 0).compareTo(x.$1.year ?? 0));
      }
    }
  } catch (_) {}
  return ArtistExtra(fans: fans, top: top, albums: albums);
}

/// The artist's Wikipedia summary and its address, for artists your server has no bio for.
Future<(String, String)> fetchArtistWiki(String name) async {
  var wiki = '', wikiUrl = '';
  {
    // the plain article first; for names that are also ordinary words, the "(band)" / "(musician)" one
    for (final title in [name, '$name (band)', '$name (musician)', '$name (singer)', '$name (rapper)']) {
      try {
        final j = await _get(
          Uri.https('en.wikipedia.org', '/api/rest_v1/page/summary/${Uri.encodeComponent(title.replaceAll(' ', '_'))}'),
        );
        if (j is! Map || j['type'] == 'disambiguation') continue;
        final desc = '${j['description'] ?? ''}'.toLowerCase();
        final musical = RegExp(r'band|musician|singer|rapper|duo|group|composer|songwriter|producer|dj|music')
            .hasMatch(desc);
        if (!musical) continue;
        wiki = '${j['extract'] ?? ''}'.trim();
        wikiUrl = '${((j['content_urls'] as Map?)?['mobile'] as Map?)?['page'] ?? ''}';
        if (wiki.isNotEmpty) break;
      } catch (_) {}
    }
  }
  return (wiki, wikiUrl);
}

final artistExtraProvider = FutureProvider.autoDispose.family<ArtistExtra, String>((ref, name) async {
  ref.cacheFor(const Duration(minutes: 15));
  if (!ref.watch(repoProvider).online) return const ArtistExtra();
  return fetchArtistExtra(name);
});

final artistWikiProvider = FutureProvider.autoDispose.family<(String, String), String>((ref, name) async {
  ref.cacheFor(const Duration(minutes: 15));
  if (!ref.watch(repoProvider).online) return ('', '');
  return fetchArtistWiki(name);
});

/// Your own copies of an artist's songs (from the phone's copy of the library), for matching popular songs.
final ownArtistSongsProvider = FutureProvider.autoDispose.family<List<Song>, String>(
  (ref, name) => ref.watch(dbProvider).songsByArtist(name),
);
