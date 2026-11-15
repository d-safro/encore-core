import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/settings.dart';
import 'models.dart';

/// Lyrics from the internet when your server has none. Sources (in the order set in Settings):
///   lrclib   LRCLIB (lrclib.net), a free, open lyrics database: synced or plain
///   netease  NetEase Cloud Music's public lyrics: synced, strong on Asian and popular music
///   ovh      lyrics.ovh: plain text, a last resort
/// Only the song's title, artist, album and length are sent.
const lyricsSourceNames = {'lrclib': 'LRCLIB', 'netease': 'NetEase', 'ovh': 'lyrics.ovh'};
const defaultLyricsSources = ['lrclib', 'netease', 'ovh'];

const _ua = {'User-Agent': 'Encore music player (https://github.com/d-safro/encore)'};
const _timeout = Duration(seconds: 10);

/// One possible lyrics match, for the "Choose lyrics" list.
class LyricsCandidate {
  LyricsCandidate({
    required this.source,
    required this.id,
    required this.title,
    required this.artist,
    this.seconds,
    this.synced = false,
  });
  final String source, id, title, artist;
  final int? seconds;
  final bool synced;
  String get key => '$source|$id';
}

/// Best online lyrics for [s]: the first synced match from the enabled sources; plain text only if no
/// source has synced lyrics. A match the user picked by hand (Choose lyrics) always wins.
Future<Lyrics> onlineLyrics(Song s, List<String> sources) async {
  final picked = pickedLyrics(s.id);
  if (picked != null) {
    final l = await loadCandidate(picked);
    if (!l.isEmpty) return l;
  }
  if (s.title.isEmpty) return const Lyrics();
  Lyrics? plain;
  for (final src in sources) {
    final l = await _bestFrom(src, s);
    if (l.isEmpty) continue;
    if (l.synced) return l;
    plain ??= l;
  }
  return plain ?? const Lyrics();
}

Future<Lyrics> _bestFrom(String src, Song s) async {
  try {
    switch (src) {
      case 'lrclib':
        return await _lrclibGet(s);
      case 'netease':
        final hits = await _neteaseSearch(s.title, s.artist);
        final best = _bestMatch(hits, s);
        return best == null ? const Lyrics() : await loadCandidate(best.key);
      case 'ovh':
        return await _ovh(s.artist, s.title);
    }
  } catch (_) {}
  return const Lyrics();
}

/// Matches from every source, for choosing by hand.
Future<List<LyricsCandidate>> searchLyrics(String title, String artist) async {
  final results = await Future.wait([
    _lrclibSearch(title, artist).catchError((_) => <LyricsCandidate>[]),
    _neteaseSearch(title, artist).catchError((_) => <LyricsCandidate>[]),
  ]);
  return [
    ...results.expand((l) => l),
    if (artist.isNotEmpty && title.isNotEmpty)
      LyricsCandidate(source: 'ovh', id: '$artist\n$title', title: title, artist: artist),
  ];
}

/// Lyrics for a candidate key ("source|id").
Future<Lyrics> loadCandidate(String key) async {
  final i = key.indexOf('|');
  if (i < 0) return const Lyrics();
  final src = key.substring(0, i), id = key.substring(i + 1);
  try {
    switch (src) {
      case 'lrclib':
        return _fromLrclib(await _json(Uri.https('lrclib.net', '/api/get/$id')));
      case 'netease':
        final j = await _json(
          Uri.https('music.163.com', '/api/song/lyric', {'id': id, 'lv': '-1', 'kv': '-1', 'tv': '-1'}),
        );
        final lrc = '${(j?['lrc'] as Map?)?['lyric'] ?? ''}';
        if (lrc.trim().isEmpty) return const Lyrics();
        final l = parseLrc(lrc, dropCredits: true);
        return l.isEmpty ? const Lyrics() : l.withSource('NetEase');
      case 'ovh':
        final p = id.split('\n');
        return p.length == 2 ? await _ovh(p[0], p[1]) : const Lyrics();
    }
  } catch (_) {}
  return const Lyrics();
}

// ── Remembered picks (per song) ──
Map<String, dynamic> _picks() {
  try {
    return jsonDecode(prefs.getString('lyricsPicks') ?? '{}') as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
}

String? pickedLyrics(String songId) {
  final v = _picks()[songId];
  return v is String ? v : null;
}

/// Remember (or forget, with null) the lyrics chosen by hand for a song.
void pickLyrics(String songId, String? key) {
  final m = _picks();
  if (key == null) {
    m.remove(songId);
  } else {
    m[songId] = key;
    if (m.length > 2000) m.remove(m.keys.first);
  }
  prefs.setString('lyricsPicks', jsonEncode(m));
}

// ── LRCLIB ──
Future<Lyrics> _lrclibGet(Song s) async {
  if (s.artist.isEmpty) return const Lyrics();
  return _fromLrclib(
    await _json(
      Uri.https('lrclib.net', '/api/get', {
        'track_name': s.title,
        'artist_name': s.artist,
        if (s.album.isNotEmpty) 'album_name': s.album,
        if (s.duration != null) 'duration': '${s.duration}',
      }),
    ),
  );
}

Lyrics _fromLrclib(Map<String, dynamic>? j) {
  if (j == null) return const Lyrics();
  final synced = '${j['syncedLyrics'] ?? ''}';
  if (synced.trim().isNotEmpty) {
    final l = parseLrc(synced);
    if (!l.isEmpty) return l.withSource('LRCLIB');
  }
  final plain = '${j['plainLyrics'] ?? ''}';
  return plain.trim().isEmpty ? const Lyrics() : Lyrics.plain(plain).withSource('LRCLIB');
}

Future<List<LyricsCandidate>> _lrclibSearch(String title, String artist) async {
  final r = await http
      .get(
        Uri.https('lrclib.net', '/api/search', {'track_name': title, if (artist.isNotEmpty) 'artist_name': artist}),
        headers: _ua,
      )
      .timeout(_timeout);
  if (r.statusCode != 200) return const [];
  final list = jsonDecode(utf8.decode(r.bodyBytes));
  if (list is! List) return const [];
  return [
    for (final e in list.take(8))
      if (e is Map && e['id'] != null && (e['syncedLyrics'] != null || e['plainLyrics'] != null))
        LyricsCandidate(
          source: 'lrclib',
          id: '${e['id']}',
          title: '${e['trackName'] ?? ''}',
          artist: '${e['artistName'] ?? ''}',
          seconds: (e['duration'] as num?)?.round(),
          synced: '${e['syncedLyrics'] ?? ''}'.trim().isNotEmpty,
        ),
  ];
}

// ── NetEase ──
Future<List<LyricsCandidate>> _neteaseSearch(String title, String artist) async {
  final j = await _json(
    Uri.https('music.163.com', '/api/search/get', {'s': '$artist $title'.trim(), 'type': '1', 'limit': '8'}),
  );
  final songs = (j?['result'] as Map?)?['songs'];
  if (songs is! List) return const [];
  return [
    for (final e in songs)
      if (e is Map && e['id'] != null)
        LyricsCandidate(
          source: 'netease',
          id: '${e['id']}',
          title: '${e['name'] ?? ''}',
          artist: [
            for (final a in (e['artists'] as List? ?? const []))
              if (a is Map) '${a['name'] ?? ''}',
          ].join(', '),
          seconds: e['duration'] is num ? ((e['duration'] as num) / 1000).round() : null,
          synced: true,
        ),
  ];
}

// ── lyrics.ovh ──
Future<Lyrics> _ovh(String artist, String title) async {
  if (artist.isEmpty || title.isEmpty) return const Lyrics();
  String part(String x) => x.replaceAll('/', ' ').replaceAll('?', '').trim();
  final j = await _json(Uri.https('api.lyrics.ovh', '/v1/${part(artist)}/${part(title)}'));
  final text = '${j?['lyrics'] ?? ''}'.replaceAll('\r', '').trim();
  return text.isEmpty ? const Lyrics() : Lyrics.plain(text).withSource('lyrics.ovh');
}

// ── Helpers ──
Future<Map<String, dynamic>?> _json(Uri u) async {
  final r = await http.get(u, headers: _ua).timeout(_timeout);
  if (r.statusCode != 200) return null;
  final j = jsonDecode(utf8.decode(r.bodyBytes));
  return j is Map<String, dynamic> ? j : null;
}

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\(.*?\)|\[.*?\]|feat\..*$|ft\..*$'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

/// The candidate whose title and artist match and whose length is close (within 10 s when both are known).
LyricsCandidate? _bestMatch(List<LyricsCandidate> hits, Song s) {
  final t = _norm(s.title), a = _norm(s.artist);
  if (t.isEmpty) return null;
  for (final h in hits) {
    final ht = _norm(h.title), ha = _norm(h.artist);
    if (ht.isEmpty) continue;
    final titleOk = ht == t || ht.startsWith(t) || t.startsWith(ht);
    final artistOk = a.isEmpty || ha.contains(a) || (ha.isNotEmpty && a.contains(ha.split(' ').first));
    final lengthOk = s.duration == null || h.seconds == null || (s.duration! - h.seconds!).abs() <= 10;
    if (titleOk && artistOk && lengthOk) return h;
  }
  return null;
}

final _credit = RegExp(
  r'^\s*(作词|作曲|编曲|制作人|混音|母带|和声|吉他|贝斯|鼓|录音|监制|出品|制作|演唱|Lyricist|Lyrics by|Composer|Composed by|Arranger|Producer)\s*[:：]',
  caseSensitive: false,
);

/// "[01:23.45] line" → timed lines. [dropCredits] leaves out "作词 : …"-style credit lines (NetEase).
Lyrics parseLrc(String text, {bool dropCredits = false}) {
  final re = RegExp(r'\[(\d+):(\d+)(?:[.:](\d+))?\]');
  final lines = <LyricLine>[];
  for (final raw in text.split('\n')) {
    final stamps = re.allMatches(raw).toList();
    if (stamps.isEmpty) continue;
    final words = raw.substring(stamps.last.end).trim();
    if (dropCredits && _credit.hasMatch(words)) continue;
    for (final m in stamps) {
      final frac = m.group(3) ?? '0';
      final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
      lines.add(
        LyricLine(Duration(minutes: int.parse(m.group(1)!), seconds: int.parse(m.group(2)!), milliseconds: ms), words),
      );
    }
  }
  lines.sort((a, b) => a.start!.compareTo(b.start!));
  return Lyrics(synced: lines.isNotEmpty, lines: lines);
}
