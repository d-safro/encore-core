import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Lyrics from LRCLIB (lrclib.net, a free and open lyrics database) when the server has none.
/// Only the song's title, artist, album and length are sent.
Future<Lyrics> lrclibLyrics(Song s) async {
  if (s.title.isEmpty || s.artist.isEmpty) return const Lyrics();
  final params = {
    'track_name': s.title,
    'artist_name': s.artist,
    if (s.album.isNotEmpty) 'album_name': s.album,
    if (s.duration != null) 'duration': '${s.duration}',
  };
  try {
    final res = await http
        .get(Uri.https('lrclib.net', '/api/get', params), headers: {'User-Agent': 'Encore music player'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return const Lyrics();
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final synced = (j['syncedLyrics'] ?? '').toString();
    if (synced.trim().isNotEmpty) return parseLrc(synced);
    final plain = (j['plainLyrics'] ?? '').toString();
    if (plain.trim().isNotEmpty) return Lyrics.plain(plain);
  } catch (_) {}
  return const Lyrics();
}

/// "[01:23.45] line" → timed lines.
Lyrics parseLrc(String text) {
  final re = RegExp(r'\[(\d+):(\d+)(?:[.:](\d+))?\]');
  final lines = <LyricLine>[];
  for (final raw in text.split('\n')) {
    final stamps = re.allMatches(raw).toList();
    if (stamps.isEmpty) continue;
    final words = raw.substring(stamps.last.end).trim();
    for (final m in stamps) {
      final frac = m.group(3) ?? '0';
      final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
      lines.add(LyricLine(
          Duration(minutes: int.parse(m.group(1)!), seconds: int.parse(m.group(2)!), milliseconds: ms), words));
    }
  }
  lines.sort((a, b) => a.start!.compareTo(b.start!));
  return Lyrics(synced: lines.isNotEmpty, lines: lines);
}
