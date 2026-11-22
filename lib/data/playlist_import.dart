import 'dart:convert';

import 'models.dart';
import 'subsonic.dart';

/// Import a playlist from another app (Library > Playlists > Import): the exports those apps and tools make,
/// matched against your library; songs you don't have can be got (⬇, the server downloads them), and the
/// playlist is made on your server like any other.
///
/// Read: CSV (Exportify, TuneMyMusic, Soundiiz and the like: a title and an artist column), Spotify's own
/// "Download your data" JSON (Playlist1.json: every playlist; YourLibrary.json: liked songs), M3U / M3U8
/// (#EXTINF lines, else file names) and plain text (one "Artist - Title" a line).

class ImportEntry {
  const ImportEntry(this.title, this.artist, {this.album = ''});
  final String title, artist, album;
  @override
  String toString() => '$artist - $title';
}

class ImportedPlaylist {
  const ImportedPlaylist(this.name, this.entries);
  final String name;
  final List<ImportEntry> entries;
}

String _baseName(String file) {
  final n = file.split(RegExp(r'[\\/]')).last;
  final dot = n.lastIndexOf('.');
  return dot > 0 ? n.substring(0, dot) : n;
}

/// The playlists in a file (several from Spotify's JSON; one otherwise, named after the file).
List<ImportedPlaylist> parsePlaylistFile(String fileName, String text) {
  final name = _baseName(fileName);
  final t = text.replaceFirst('﻿', '').trim();
  if (t.isEmpty) return const [];
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      return _spotifyJson(jsonDecode(t), name);
    } catch (_) {
      return const [];
    }
  }
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.m3u') || lower.endsWith('.m3u8') || t.startsWith('#EXTM3U')) {
    return [ImportedPlaylist(name, _m3u(t))];
  }
  if (lower.endsWith('.csv') || lower.endsWith('.tsv')) {
    final csv = _csv(t, separator: lower.endsWith('.tsv') ? '\t' : null);
    if (csv.isNotEmpty) return [ImportedPlaylist(name, csv)];
  }
  return [ImportedPlaylist(name, _lines(t))];
}

List<ImportedPlaylist> _spotifyJson(Object? j, String name) {
  ImportEntry? track(Object? x) {
    if (x is! Map) return null;
    final m = x['track'] is Map ? x['track'] as Map : x;
    final title = '${m['trackName'] ?? m['track'] ?? m['name'] ?? ''}'.trim();
    final artist = '${m['artistName'] ?? m['artist'] ?? ''}'.trim();
    if (title.isEmpty) return null;
    return ImportEntry(title, artist, album: '${m['albumName'] ?? m['album'] ?? ''}'.trim());
  }

  if (j is Map && j['playlists'] is List) {
    return [
      for (final p in j['playlists'] as List)
        if (p is Map)
          ImportedPlaylist('${p['name'] ?? name}', [for (final i in (p['items'] as List? ?? const [])) ?track(i)]),
    ];
  }
  if (j is Map && j['tracks'] is List) {
    return [ImportedPlaylist('Liked songs from Spotify', [for (final i in j['tracks'] as List) ?track(i)])];
  }
  if (j is List) return [ImportedPlaylist(name, [for (final i in j) ?track(i)])];
  return const [];
}

List<ImportEntry> _m3u(String t) {
  final out = <ImportEntry>[];
  String? info;
  for (final raw in const LineSplitter().convert(t)) {
    final l = raw.trim();
    if (l.startsWith('#EXTINF')) {
      final comma = l.indexOf(',');
      info = comma > 0 ? l.substring(comma + 1).trim() : null;
    } else if (l.isNotEmpty && !l.startsWith('#')) {
      final e = _artistTitle(info ?? _baseName(Uri.decodeFull(l)));
      if (e != null) out.add(e);
      info = null;
    }
  }
  return out;
}

List<ImportEntry> _lines(String t) => [
  for (final l in const LineSplitter().convert(t)) ?_artistTitle(l.trim()),
];

/// "Artist - Title" (or "03. Artist - Title"); a line with no " - " is a title alone.
ImportEntry? _artistTitle(String s) {
  var x = s.replaceFirst(RegExp(r'^\d{1,3}[.)\s-]+\s*'), '').trim();
  if (x.isEmpty) return null;
  for (final sep in [' – ', ' — ', ' - ']) {
    final i = x.indexOf(sep);
    if (i > 0) return ImportEntry(x.substring(i + sep.length).trim(), x.substring(0, i).trim());
  }
  return ImportEntry(x, '');
}

/// CSV with a header naming the title and the artist columns.
List<ImportEntry> _csv(String t, {String? separator}) {
  final rows = parseCsv(t, separator: separator ?? (t.split('\n').first.contains(';') && !t.split('\n').first.contains(',') ? ';' : ','));
  if (rows.length < 2) return const [];
  final head = [for (final h in rows.first) h.trim().toLowerCase()];
  // the first name that's a header exactly, else one a header starts with (never an id / uri / url column:
  // Exportify's "Track URI" isn't the title)
  int find(List<String> names) {
    bool idLike(String h) => RegExp(r'\b(uri|url|id|isrc|link)\b').hasMatch(h);
    for (final n in names) {
      final i = head.indexOf(n);
      if (i >= 0) return i;
    }
    for (final n in names) {
      final i = head.indexWhere((h) => h.startsWith(n) && !idLike(h));
      if (i >= 0) return i;
    }
    return -1;
  }
  final ti = find(['track name', 'track title', 'title', 'song name', 'song', 'track', 'name']);
  final ar = find(['artist name', 'artist(s)', 'artists', 'artist', 'creator', 'performer']);
  final al = find(['album name', 'album title', 'album']);
  if (ti < 0) return const [];
  return [
    for (final r in rows.skip(1))
      if (r.length > ti && r[ti].trim().isNotEmpty)
        ImportEntry(
          r[ti].trim(),
          ar >= 0 && r.length > ar ? r[ar].split(RegExp(r'[;,]')).first.trim() : '', // the first of several artists
          album: al >= 0 && r.length > al ? r[al].trim() : '',
        ),
  ];
}

/// RFC 4180-ish: quoted fields with commas, quotes ("") and new lines.
List<List<String>> parseCsv(String t, {String separator = ','}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final f = StringBuffer();
  var quoted = false;
  for (var i = 0; i < t.length; i++) {
    final c = t[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < t.length && t[i + 1] == '"') {
          f.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        f.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == separator) {
      row.add(f.toString());
      f.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < t.length && t[i + 1] == '\n') i++;
      row.add(f.toString());
      f.clear();
      if (row.any((x) => x.isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      f.write(c);
    }
  }
  row.add(f.toString());
  if (row.any((x) => x.isNotEmpty)) rows.add(row);
  return rows;
}

// ── Matching ──
/// For comparing: lower case, no "(Remastered 2011)" / "- Live" / "feat." parts, letters and digits only.
String normTitle(String s) {
  var x = s.toLowerCase();
  x = x.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*(remaster|version|edit|mix|live|mono|stereo|feat|ft\.|deluxe|bonus)[^\)\]]*[\)\]]'), '');
  x = x.replaceAll(RegExp(r'\s+-\s+.*(remaster|version|edit|live|mono|stereo).*$'), '');
  x = x.replaceAll(RegExp(r'\s+(feat\.?|ft\.?|featuring)\s+.*$'), '');
  return x.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');
}

String normArtist(String s) =>
    s.toLowerCase().replaceFirst(RegExp(r'^the\s+'), '').replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

/// The best song for an entry among search results: same title (and artist, when known); one in your
/// library before one you don't have (⬇).
Song? bestMatch(ImportEntry e, List<Song> found) {
  final t = normTitle(e.title), a = normArtist(e.artist);
  bool artistOk(Song s) {
    if (a.isEmpty) return true;
    final x = normArtist(s.artist);
    return x.isNotEmpty && (x.contains(a) || a.contains(x));
  }
  final same = [for (final s in found) if (normTitle(s.title) == t && artistOk(s)) s];
  if (same.isEmpty) return null;
  return same.firstWhere((s) => !s.isLookup, orElse: () => same.first);
}

/// Look an entry up on your server (its search also finds songs you don't have, through music-lookup).
Future<Song?> matchEntry(SubsonicClient c, ImportEntry e) async {
  try {
    final r = await c.search('${e.artist} ${e.title}'.trim(), artistCount: 0, albumCount: 0, songCount: 15);
    return bestMatch(e, r.songs) ??
        (e.artist.isEmpty ? null : bestMatch(e, (await c.search(e.title, artistCount: 0, albumCount: 0, songCount: 25)).songs));
  } catch (_) {
    return null;
  }
}
