import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/settings.dart';

/// Cover art from the internet for albums / artists your server has no picture for.
/// Albums: iTunes Search, then Deezer. Artists: Deezer. Only the artist and album name are sent.
/// Results (also "nothing found") are remembered on the phone, so each one is looked up once.
class OnlineArt {
  static Map<String, String>? _cache;

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
    _mem[key] = url;
    if (_mem.length > 3000) _mem.remove(_mem.keys.first);
    prefs.setString('onlineArt', jsonEncode(_mem));
  }

  static Future<Map<String, dynamic>?> _json(Uri u) async {
    try {
      final r = await http.get(u, headers: {'User-Agent': 'Encore music player'}).timeout(const Duration(seconds: 8));
      return r.statusCode == 200 ? jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic> : null;
    } catch (_) {
      return null;
    }
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  static Future<String?> album(String artist, String album) async {
    if (artist.isEmpty && album.isEmpty) return null;
    final key = 'al|${_norm(artist)}|${_norm(album)}';
    if (_mem.containsKey(key)) return _mem[key]!.isEmpty ? null : _mem[key];
    String url = '';
    final it = await _json(
      Uri.https('itunes.apple.com', '/search', {'term': '$artist $album', 'entity': 'album', 'limit': '5'}),
    );
    for (final r in (it?['results'] as List? ?? const [])) {
      final m = (r as Map).cast<String, dynamic>();
      if (_norm('${m['artistName']}').contains(_norm(artist)) || _norm(artist).contains(_norm('${m['artistName']}'))) {
        url = '${m['artworkUrl100'] ?? ''}'.replaceFirst('100x100bb', '600x600bb');
        if (url.isNotEmpty) break;
      }
    }
    if (url.isEmpty) {
      final dz = await _json(
        Uri.https('api.deezer.com', '/search/album', {'q': 'artist:"$artist" album:"$album"', 'limit': '1'}),
      );
      final d = (dz?['data'] as List?)?.cast<Map>() ?? const [];
      if (d.isNotEmpty) url = '${d.first['cover_xl'] ?? d.first['cover_big'] ?? ''}';
    }
    _remember(key, url);
    return url.isEmpty ? null : url;
  }

  static Future<String?> artist(String name) async {
    if (name.isEmpty) return null;
    final key = 'ar|${_norm(name)}';
    if (_mem.containsKey(key)) return _mem[key]!.isEmpty ? null : _mem[key];
    var url = '';
    final dz = await _json(Uri.https('api.deezer.com', '/search/artist', {'q': name, 'limit': '1'}));
    final d = (dz?['data'] as List?)?.cast<Map>() ?? const [];
    if (d.isNotEmpty && _norm('${d.first['name']}') == _norm(name)) {
      final pic = '${d.first['picture_xl'] ?? ''}';
      if (!pic.contains('/artist//')) url = pic; // Deezer's grey "no picture" image
    }
    _remember(key, url);
    return url.isEmpty ? null : url;
  }
}

/// (kind, artist, album) → image URL, or null. kind is 'album' or 'artist'.
final onlineArtProvider = FutureProvider.family<String?, (String, String, String)>((ref, k) async {
  if (!ref.watch(settingsProvider.select((s) => s.onlineCovers))) return null;
  return k.$1 == 'artist' ? OnlineArt.artist(k.$2) : OnlineArt.album(k.$2, k.$3);
});
