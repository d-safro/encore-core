import 'dart:async';

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

  /// "Made for you" from the server itself (Conductor's encore.forYou), for a server without AudioMuse-AI.
  Future<List<Song>> forYouFromServer({int n = 60}) async => c.forYouMix(count: n);

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

/// Whether the server offers AudioMuse-AI at all (found out once, see [SubsonicClient.offersAudiomuse]):
/// without it, Discover says so instead of showing mixes that can't be made. False offline.
/// Whether the server makes "Made for you" itself, without AudioMuse-AI (Conductor 0.6 and later: encore.forYou).
final forYouOfferedProvider = FutureProvider.autoDispose<bool>((ref) async {
  ref.cacheFor(const Duration(minutes: 30));
  final ai = ref.watch(aiProvider);
  if (ai == null) return false;
  final names = await ai.c.openSubsonicExtensions();
  if (names.isEmpty) {
    // no answer (Navidrome and Conductor always list some): ask again soon rather than keep "no" for half an hour
    final again = Timer(const Duration(seconds: 30), ref.invalidateSelf);
    ref.onDispose(again.cancel);
  }
  return names.contains('encore.forYou');
});

/// "Made for you" from whichever the server has: AudioMuse-AI's sound-alikes, else Conductor's own mix (also when
/// AudioMuse-AI has nothing yet or can't be reached). Empty when it has neither (or is out of reach).
Future<List<Song>> madeForYou(WidgetRef ref, {int n = 60}) async {
  final ai = ref.read(aiProvider);
  if (ai == null) return const [];
  if (await ref.read(aiOfferedProvider.future)) {
    try {
      final songs = await ai.forYou(n: n);
      if (songs.isNotEmpty) return songs;
    } catch (_) {
      if (!await ref.read(forYouOfferedProvider.future)) rethrow;
    }
  }
  if (await ref.read(forYouOfferedProvider.future)) return ai.forYouFromServer(n: n);
  return const [];
}

final aiOfferedProvider = FutureProvider.autoDispose<bool>((ref) async {
  ref.cacheFor(const Duration(minutes: 30));
  final ai = ref.watch(aiProvider);
  return ai != null && await ai.c.offersAudiomuse();
});
