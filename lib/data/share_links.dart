import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Share links anyone can open: song.link / album.link / artist.link pages (by Odesli), which send the
/// friend to the same music on Spotify, Apple Music, YouTube, Deezer... whatever they use.
/// The song is found on Deezer first: by its ISRC recording code when the file has one (exact), else by
/// artist + title + length. Only those names / codes are sent.

const _ua = {'User-Agent': 'Encore music player (https://github.com/d-safro/encore)'};

String? _dz(String id, String kind) {
  final p = 'dz-$kind-';
  return id.startsWith(p) && int.tryParse(id.substring(p.length)) != null ? id.substring(p.length) : null;
}

Future<dynamic> _get(String path, [Map<String, String>? q]) async {
  final r = await http.get(Uri.https('api.deezer.com', path, q), headers: _ua).timeout(const Duration(seconds: 10));
  if (r.statusCode != 200) return null;
  return jsonDecode(utf8.decode(r.bodyBytes));
}

String _n(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\(.*?\)|\[.*?\]|feat\..*$|ft\..*$| - .*remaster.*$'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

String _q(String s) => s.replaceAll('"', ' ');

/// song.link page for a song, or null when it can't be found anywhere.
Future<String?> songLink(Song s) async {
  var id = _dz(s.id, 't');
  if (id == null && s.isrc.isNotEmpty) {
    final j = await _get('/track/isrc:${s.isrc}');
    if (j is Map && j['id'] != null) id = '${j['id']}';
  }
  if (id == null) {
    final j = await _get('/search', {'q': 'artist:"${_q(s.artist)}" track:"${_q(s.title)}"', 'limit': '10'});
    final list = j is Map && j['data'] is List ? j['data'] as List : const [];
    final t = _n(s.title);
    Map? best;
    for (final e in list) {
      if (e is! Map) continue;
      final titleOk = _n('${e['title']}') == t || _n('${e['title_short'] ?? ''}') == t;
      if (!titleOk) continue;
      final len = (e['duration'] as num?)?.toInt();
      if (s.duration != null && len != null && (s.duration! - len).abs() > 15) {
        best ??= e; // same song, other length: only if nothing closer
        continue;
      }
      best = e;
      break;
    }
    best ??= list.isNotEmpty && list.first is Map ? list.first as Map : null;
    if (best != null) id = '${best['id']}';
  }
  return id == null ? null : 'https://song.link/d/$id';
}

/// album.link page for an album.
Future<String?> albumLink(Album a) async {
  var id = _dz(a.id, 'a');
  if (id == null) {
    final j = await _get('/search/album', {'q': 'artist:"${_q(a.artist)}" album:"${_q(a.name)}"', 'limit': '10'});
    final list = j is Map && j['data'] is List ? j['data'] as List : const [];
    final n = _n(a.name);
    final hit =
        list.whereType<Map>().where((e) => _n('${e['title']}') == n).firstOrNull ??
        (list.isNotEmpty && list.first is Map ? list.first as Map : null);
    if (hit != null) id = '${hit['id']}';
  }
  return id == null ? null : 'https://album.link/d/$id';
}

/// artist.link page for an artist.
Future<String?> artistLink(String artistId, String name) async {
  var id = _dz(artistId, 'r');
  if (id == null) {
    final j = await _get('/search/artist', {'q': name, 'limit': '5'});
    final list = j is Map && j['data'] is List ? j['data'] as List : const [];
    final n = _n(name);
    final hit = list.whereType<Map>().where((e) => _n('${e['name']}') == n).firstOrNull;
    if (hit != null) id = '${hit['id']}';
  }
  return id == null ? null : 'https://artist.link/d/$id';
}
