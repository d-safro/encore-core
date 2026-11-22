import 'dart:convert';

import '../core/settings.dart';
import '../data/models.dart';

/// "Not for me": songs and artists you don't want suggested. They're left out of everything Encore and your
/// server pick for you (autoplay, smart shuffle, song radio, instant mixes, the weekly mixes), but still play
/// when you choose them. Kept in the pref `notForMe` ({"songs": [{id, title, artist}], "artists": [name]}),
/// synced to your other devices and read by the server's mixes.

String _norm(String s) => s.trim().toLowerCase();

class NotForMe {
  const NotForMe({this.songs = const [], this.artists = const []});
  final List<(String, String, String)> songs; // id, title, artist
  final List<String> artists;

  Set<String> get songIds => {for (final s in songs) s.$1};
  Set<String> get artistKeys => {for (final a in artists) _norm(a)};

  bool blocks(Song s) => songIds.contains(s.id) || (artists.isNotEmpty && artistKeys.contains(_norm(s.artist)));

  Map<String, dynamic> toJson() => {
    'songs': [for (final s in songs) {'id': s.$1, 'title': s.$2, 'artist': s.$3}],
    'artists': artists,
  };

  static NotForMe fromJson(Object? j) {
    if (j is! Map) return const NotForMe();
    return NotForMe(
      songs: [
        for (final s in (j['songs'] as List? ?? const []))
          if (s is Map && s['id'] != null) ('${s['id']}', '${s['title'] ?? ''}', '${s['artist'] ?? ''}'),
      ],
      artists: [for (final a in (j['artists'] as List? ?? const [])) if ('$a'.trim().isNotEmpty) '$a'],
    );
  }
}

String? _raw;
NotForMe _parsed = const NotForMe();

/// Read often (each suggestion is checked): parsed again only when the pref changed.
NotForMe notForMe() {
  String raw;
  try {
    raw = prefs.getString('notForMe') ?? '{}';
  } catch (_) {
    return const NotForMe(); // prefs not ready (tests, very early start)
  }
  if (raw == _raw) return _parsed;
  _raw = raw;
  try {
    return _parsed = NotForMe.fromJson(jsonDecode(raw));
  } catch (_) {
    return _parsed = const NotForMe();
  }
}

Future<void> _save(NotForMe n) => prefs.setString('notForMe', jsonEncode(n.toJson()));

Future<void> blockSong(Song s) async {
  final n = notForMe();
  if (n.songIds.contains(s.id)) return;
  await _save(NotForMe(songs: [...n.songs, (s.id, s.title, s.artist)], artists: n.artists));
}

Future<void> blockArtist(String name) async {
  final n = notForMe();
  if (n.artistKeys.contains(_norm(name))) return;
  await _save(NotForMe(songs: n.songs, artists: [...n.artists, name]));
}

Future<void> unblockSong(String id) async {
  final n = notForMe();
  await _save(NotForMe(songs: n.songs.where((s) => s.$1 != id).toList(), artists: n.artists));
}

Future<void> unblockArtist(String name) async {
  final n = notForMe();
  await _save(NotForMe(songs: n.songs, artists: n.artists.where((a) => _norm(a) != _norm(name)).toList()));
}
