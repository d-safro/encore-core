import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/settings.dart';

/// Cover art from the internet for albums / artists your server has no picture for.
/// Albums: iTunes Search, then Deezer. Artists: Deezer. Only the artist and album name are sent.
/// Results are remembered on the phone, so each one is looked up once; "nothing found" is asked again
/// after two weeks, and a lookup that failed (no network, rate limit) isn't remembered at all.
class OnlineArt {
  static Map<String, String>? _cache;
  static Timer? _save;
  static int get _today => DateTime.now().millisecondsSinceEpoch ~/ 86400000;

  /// null: ask; '': known to have none; else the picture's address.
  static String? _known(String key) {
    final v = _mem[key];
    if (v == null || v.isEmpty) return null; // '' was the old "none" mark: ask again with today's matching
    if (v.startsWith('-')) return _today - (int.tryParse(v.substring(1)) ?? 0) < 14 ? '' : null;
    return v;
  }

  static Map<String, String> get _mem {
    if (_cache != null) return _cache!;
    try {
      _cache = (jsonDecode(prefs.getString('onlineArt') ?? '{}') as Map).cast<String, String>();
    } catch (_) {
      _cache = {};
    }
    return _cache!;
  }

  static void _remember(String key, String url) {
    _mem.remove(key);
    _mem[key] = url.isEmpty ? '-$_today' : url;
    if (_mem.length > 3000) _mem.remove(_mem.keys.first);
    // written once things settle, not once per cover (it's one big entry)
    _save?.cancel();
    _save = Timer(const Duration(seconds: 3), () => prefs.setString('onlineArt', jsonEncode(_mem)));
  }


  static Future<Map<String, dynamic>?> _json(Uri u) async {
    try {
      final r = await http.get(u, headers: {'User-Agent': 'Encore music player'}).timeout(const Duration(seconds: 8));
      return r.statusCode == 200 ? jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic> : null;
    } catch (_) {
      return null; // null = the lookup failed (not "nothing found")
    }
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  static Future<String?> album(String artist, String album) async {
    if (artist.isEmpty && album.isEmpty) return null;
    final key = 'al|${_norm(artist)}|${_norm(album)}';
    final known = _known(key);
    if (known != null) return known.isEmpty ? null : known;
    var failed = false;
    String url = '';
    // what's in brackets ("[CD-M+342-9]", "(Remastered)") only gets in the way of a search
    final title = album.replaceAll(RegExp(r'\s*[\(\[].*?[\)\]]'), '').trim();
    final na = _norm(artist), nt = _norm(title);
    // the directories may spell a Cyrillic / Japanese / … name in Latin letters ("Otava Yo" for "Отава Ё"):
    // then the album title has to match exactly instead
    final latin = !RegExp(r'[^\x00-\x7F]').hasMatch(artist);
    bool fits(String a, String t) {
      final sameArtist = na.isNotEmpty && (_norm(a).contains(na) || na.contains(_norm(a)));
      final sameTitle = nt.isNotEmpty && _norm(t) == nt;
      return latin ? sameArtist : (sameArtist || (sameTitle && nt.length >= 4));
    }
    final it = await _json(
      Uri.https('itunes.apple.com', '/search', {'term': '$artist $title', 'entity': 'album', 'limit': '5'}),
    );
    failed |= it == null;
    for (final r in (it?['results'] as List? ?? const [])) {
      final m = (r as Map).cast<String, dynamic>();
      if (fits('${m['artistName']}', '${m['collectionName']}')) {
        url = '${m['artworkUrl100'] ?? ''}'.replaceFirst('100x100bb', '600x600bb');
        if (url.isNotEmpty) break;
      }
    }
    if (url.isEmpty) {
      // a plain search: Deezer's artist:"…" album:"…" form finds nothing for many non-Latin names
      final dz = await _json(Uri.https('api.deezer.com', '/search/album', {'q': '$artist $title', 'limit': '5'}));
      failed |= dz == null;
      for (final d in (dz?['data'] as List?)?.cast<Map>() ?? const <Map>[]) {
        if (fits('${(d['artist'] as Map?)?['name'] ?? ''}', '${d['title'] ?? ''}')) {
          url = '${d['cover_xl'] ?? d['cover_big'] ?? ''}';
          if (url.isNotEmpty) break;
        }
      }
    }
    if (url.isNotEmpty || !failed) _remember(key, url);
    return url.isEmpty ? null : url;
  }

  static Future<String?> artist(String name) async {
    if (name.isEmpty) return null;
    final key = 'ar|${_norm(name)}';
    final known = _known(key);
    if (known != null) return known.isEmpty ? null : known;
    var failed = false;
    var url = '';
    final dz = await _json(Uri.https('api.deezer.com', '/search/artist', {'q': name, 'limit': '1'}));
    failed |= dz == null;
    final d = (dz?['data'] as List?)?.cast<Map>() ?? const [];
    if (d.isNotEmpty && _norm('${d.first['name']}') == _norm(name)) {
      final pic = '${d.first['picture_xl'] ?? ''}';
      if (!pic.contains('/artist//')) url = pic; // Deezer's grey "no picture" image
    }
    if (url.isNotEmpty || !failed) _remember(key, url);
    return url.isEmpty ? null : url;
  }
}

/// (kind, artist, album) → image URL, or null. kind is 'album' or 'artist'.
final onlineArtProvider = FutureProvider.family<String?, (String, String, String)>((ref, k) async {
  if (!ref.watch(settingsProvider.select((s) => s.onlineCovers))) return null;
  return k.$1 == 'artist' ? OnlineArt.artist(k.$2) : OnlineArt.album(k.$2, k.$3);
});
