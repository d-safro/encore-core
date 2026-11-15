import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/settings.dart';

/// A station from Radio Browser (radio-browser.info), the free, community-run directory of internet radio.
/// Only the search words are sent.
class RadioBrowserStation {
  RadioBrowserStation({
    required this.name,
    required this.url,
    this.homepage = '',
    this.favicon = '',
    this.country = '',
    this.codec = '',
    this.bitrate = 0,
    this.tags = '',
  });
  final String name, url, homepage, favicon, country, codec, tags;
  final int bitrate;

  String get details => [
    if (country.isNotEmpty) country,
    if (codec.isNotEmpty) bitrate > 0 ? '$codec $bitrate kbps' : codec,
    if (tags.isNotEmpty) tags.split(',').take(3).join(', '),
  ].join(' · ');
}

const _mirrors = ['de1.api.radio-browser.info', 'fi1.api.radio-browser.info', 'at1.api.radio-browser.info'];
const _ua = {'User-Agent': 'Encore music player (https://github.com/d-safro/encore)'};

/// Stations whose name matches [q] (most listened first); empty [q] gives the most popular ones.
Future<List<RadioBrowserStation>> searchStations(String q) async {
  final params = {
    if (q.trim().isNotEmpty) 'name': q.trim(),
    'limit': '40',
    'hidebroken': 'true',
    'order': 'clickcount',
    'reverse': 'true',
  };
  for (final host in _mirrors) {
    try {
      final r = await http
          .get(Uri.https(host, '/json/stations/search', params), headers: _ua)
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) continue;
      final list = jsonDecode(utf8.decode(r.bodyBytes));
      if (list is! List) continue;
      final seen = <String>{};
      return [
        for (final e in list)
          if (e is Map && '${e['url_resolved'] ?? e['url'] ?? ''}'.startsWith('http') && seen.add('${e['name']}'))
            RadioBrowserStation(
              name: '${e['name'] ?? ''}'.trim(),
              url: '${(e['url_resolved'] ?? '').toString().isNotEmpty ? e['url_resolved'] : e['url']}',
              homepage: '${e['homepage'] ?? ''}',
              favicon: '${e['favicon'] ?? ''}',
              country: '${e['countrycode'] ?? ''}',
              codec: '${e['codec'] ?? ''}',
              bitrate: (e['bitrate'] as num?)?.toInt() ?? 0,
              tags: '${e['tags'] ?? ''}',
            ),
      ];
    } catch (_) {
      // try the next mirror
    }
  }
  throw Exception("Couldn't reach the radio directory");
}

// Station pictures: Navidrome doesn't store one, so the app remembers the directory's picture by stream address.
Map<String, dynamic> _art() {
  try {
    return jsonDecode(prefs.getString('radioArt') ?? '{}') as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
}

String? stationArt(String streamUrl) {
  final v = _art()[streamUrl];
  return v is String && v.startsWith('http') ? v : null;
}

void rememberStationArt(String streamUrl, String favicon) {
  if (!favicon.startsWith('http')) return;
  final m = _art()..[streamUrl] = favicon;
  if (m.length > 500) m.remove(m.keys.first);
  prefs.setString('radioArt', jsonEncode(m));
}
