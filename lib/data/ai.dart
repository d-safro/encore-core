import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';
import 'library.dart';
import 'models.dart';
import 'subsonic.dart';

/// A song suggested by AudioMuse-AI (its item_id is the Navidrome song id).
class AiPick {
  final String id, title, artist, album, mood, genre;
  final double? score;
  const AiPick(this.id, this.title, this.artist, this.album, this.mood, this.genre, this.score);
  factory AiPick.fromJson(Map<String, dynamic> j) => AiPick(
    (j['item_id'] ?? '').toString(),
    (j['title'] ?? '').toString(),
    (j['author'] ?? j['album_artist'] ?? '').toString(),
    (j['album'] ?? '').toString(),
    (j['top_mood'] ?? '').toString(),
    (j['top_genre'] ?? '').toString(),
    ((j['similarity'] ?? j['distance']) as num?)?.toDouble(),
  );
}

const aiMoods = {
  'happy': 'Happy',
  'relaxed': 'Relaxed',
  'sad': 'Melancholy',
  'danceable': 'Danceable',
  'party': 'Party',
  'aggressive': 'Energetic',
};

/// AudioMuse-AI features, each returning playable library songs in AudioMuse's order.
class Ai {
  Ai(this.c, this.repo);
  final SubsonicClient c;
  final Repo repo;

  List<AiPick> _picks(dynamic r) {
    final list = r is List ? r : (r is Map ? r['results'] : null);
    return list is List
        ? list
              .whereType<Map>()
              .map((e) => AiPick.fromJson(e.cast<String, dynamic>()))
              .where((p) => p.id.isNotEmpty)
              .toList()
        : const [];
  }

  Future<List<Song>> _songs(dynamic r) => repo.resolveSongs(_picks(r).map((p) => p.id).toList());

  /// "Made for you": songs that match what you listen to most.
  Future<List<Song>> forYou({int n = 60}) async =>
      _songs(await c.audiomuse('sonic_fingerprint/generate', query: {'n': n}));

  /// Describe a sound in words ("calm piano at night").
  Future<List<Song>> describe(String text, {int n = 60}) async =>
      _songs(await c.audiomuse('clap/search', body: {'query': text, 'limit': n}));

  /// Songs whose lyrics are about something ("leaving home", "summer love").
  Future<List<Song>> lyricsAbout(String text, {int n = 60}) async =>
      _songs(await c.audiomuse('lyrics/search/text', body: {'query': text, 'limit': n}));

  /// Blend songs together; subtracted songs push the mix away from their sound.
  Future<List<Song>> alchemy(List<Song> add, List<Song> subtract, {int n = 50}) async => _songs(
    await c.audiomuse(
      'alchemy',
      body: {
        'n': n,
        'items': [
          for (final s in add) {'id': s.id, 'op': 'ADD'},
          for (final s in subtract) {'id': s.id, 'op': 'SUBTRACT'},
        ],
      },
    ),
  );

  Future<List<Song>> mood(String mood, {int n = 60}) async => _songs(
    await c.audiomuse(
      'alchemy',
      body: {
        'n': n,
        'items': [
          {'id': '$mood:0', 'type': 'mood', 'op': 'ADD'},
        ],
      },
    ),
  );

  /// Artists that sound alike (by the music itself, not tags).
  Future<List<Artist>> similarArtists(String name, {int n = 12}) async {
    final r = await c.audiomuse('similar_artists', query: {'artist': name, 'n': n});
    if (r is! List) return const [];
    return r
        .whereType<Map>()
        .map((e) => Artist(id: (e['artist_id'] ?? '').toString(), name: (e['artist'] ?? '').toString()))
        .where((a) => a.name.isNotEmpty && a.name.toLowerCase() != name.toLowerCase())
        .toList();
  }

  /// Example prompts other people have used on this server's text search.
  Future<List<String>> examplePrompts() async {
    try {
      final r = await c.audiomuse('clap/top_queries');
      final q = r is Map ? r['queries'] : null;
      return q is List ? q.map((e) => e.toString()).take(12).toList() : const [];
    } catch (_) {
      return const [];
    }
  }
}

final aiProvider = Provider<Ai?>((ref) {
  final c = ref.watch(clientProvider);
  final repo = ref.watch(repoProvider);
  return c == null || !repo.online ? null : Ai(c, repo);
});
