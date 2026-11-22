import 'dart:math';

import '../data/models.dart';
import 'not_for_me.dart';

/// Autoplay: when what you chose runs out, Encore keeps going with songs like it, without end.
///
/// This file is the choosing part only (no network, no player), so it can be tested on its own.
/// The player (handler.dart) gathers candidates from several places and asks [pickAutoplay] for the next few.

/// Where a candidate came from. Each kind gets a share of the picks (see [autoplayWeights]).
enum AutoSource {
  soundAlike, // sounds like one of the last songs (AudioMuse, else Last.fm-style similar songs)
  similarArtist, // by an artist similar to one you just heard
  genre, // same genre, songs you've played before
  favourite, // your hearted songs
  frequent, // what you play most
  discovery, // same genre, songs you've never played
  anything, // anything from your library: rarely, and to fill in rather than repeat an artist
}

/// How often each kind is picked, relative to the others. Kinds with nothing left are skipped and the
/// rest share their turn, so the mix still works when only one or two places answer.
const autoplayWeights = {
  AutoSource.soundAlike: 5.0,
  AutoSource.similarArtist: 2.0,
  AutoSource.genre: 1.5,
  AutoSource.favourite: 1.5,
  AutoSource.frequent: 1.0,
  AutoSource.discovery: 1.0,
  AutoSource.anything: 0.3,
};

/// Song radio stays close to its song: almost all sound-alikes.
const radioWeights = {
  AutoSource.soundAlike: 8.0,
  AutoSource.similarArtist: 2.0,
  AutoSource.genre: 1.0,
  AutoSource.favourite: 0.5,
  AutoSource.frequent: 0.5,
  AutoSource.discovery: 0.5,
  AutoSource.anything: 0.2,
};

class AutoCandidate {
  const AutoCandidate(this.song, this.source, [this.rank = 0]);
  final Song song;
  final AutoSource source;
  final int rank; // place in the list it came from (0 = best match)
}

/// How often you skip a song versus play it through (kept on the phone).
class SkipStats {
  SkipStats([Map<String, (int, int)>? m]) : _m = m ?? {};
  final Map<String, (int, int)> _m; // id → (skips, plays)

  int skips(String id) => _m[id]?.$1 ?? 0;
  int plays(String id) => _m[id]?.$2 ?? 0;

  void skipped(String id) => _set(id, skips(id) + 1, plays(id));
  void played(String id) => _set(id, skips(id), plays(id) + 1);

  void _set(String id, int s, int p) {
    _m.remove(id); // re-added at the end: the oldest entries are the first to go
    _m[id] = (s, p);
    while (_m.length > 3000) {
      _m.remove(_m.keys.first);
    }
  }

  /// Skipped at least three times, and far more often than played through: leave it out.
  bool skipsALot(String id) {
    final s = skips(id);
    return s >= 3 && s >= 2 * (plays(id) + 1);
  }

  /// Share of the times it came on that you skipped it (0 when unknown).
  double skipShare(String id) {
    final s = skips(id), p = plays(id);
    return s + p == 0 ? 0 : s / (s + p);
  }

  Map<String, dynamic> toJson() => {
    for (final e in _m.entries) e.key: [e.value.$1, e.value.$2],
  };

  factory SkipStats.fromJson(Object? j) {
    final m = <String, (int, int)>{};
    if (j is Map) {
      for (final e in j.entries) {
        final v = e.value;
        if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
          m['${e.key}'] = ((v[0] as num).toInt(), (v[1] as num).toInt());
        }
      }
    }
    return SkipStats(m);
  }
}

/// The artist a song is "by" for spreading artists out: the main artist, without featured guests.
String artistKey(Song s) {
  var a = s.artist.toLowerCase().trim();
  for (final cut in [' feat.', ' feat ', ' ft.', ' featuring ', ' (feat', ' with ']) {
    final i = a.indexOf(cut);
    if (i > 0) a = a.substring(0, i);
  }
  return a.trim().isEmpty ? 'id:${s.artistId}' : a.trim();
}

/// The same recording on another album (a compilation, a remaster) counts as the same song.
String songKey(Song s) {
  final t = s.title.toLowerCase().replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '').replaceAll(RegExp(r'\s+'), ' ');
  return '${artistKey(s)}|${t.trim()}';
}

/// Which of the last songs played to find more like. The latest one always, plus up to [extra] others from
/// the few before it, so autoplay follows where the music went instead of circling the first song.
List<Song> chooseSeeds(List<Song> history, {Random? rng, int extra = 2, int window = 6}) {
  final usable = history.where((s) => !s.isLookup && !isPodcastId(s.id)).toList();
  if (usable.isEmpty) return const [];
  final last = usable.last;
  final before = usable.reversed.skip(1).take(window - 1).where((s) => s.id != last.id).toList();
  final seen = {last.id};
  before.retainWhere((s) => seen.add(s.id));
  before.shuffle(rng ?? Random());
  return [last, ...before.take(extra)];
}

/// Choose the next [n] songs.
///
/// - [recent]: the songs just played and still queued, oldest first (no repeats, and their artists count
///   toward the spread).
/// - [exclude]: ids that mustn't come back (played lately, already suggested, in the queue).
/// - [seedGenres] / [relatedArtists]: favourites and frequent plays that fit these come first.
List<AutoCandidate> pickAutoplay({
  required List<AutoCandidate> candidates,
  required int n,
  List<Song> recent = const [],
  Set<String> exclude = const {},
  Set<String> excludeKeys = const {}, // [songKey]s of songs played lately (the same recording on another album)
  SkipStats? skips,
  Set<String> seedGenres = const {},
  Set<String> relatedArtists = const {},
  Map<AutoSource, double> weights = autoplayWeights,
  Random? rng,
  int artistGap = 4, // songs before the same artist may come again
  int maxPerArtist = 2, // at most this many by one artist among the picks and the last 10 songs
  bool allowLookup = false, // songs you don't have may come (they're got automatically)
}) {
  final r = rng ?? Random();
  final st = skips ?? SkipStats();
  final recentKeys = {...excludeKeys, for (final s in recent) songKey(s)};
  final genres = {for (final g in seedGenres) g.toLowerCase()};

  // One entry per song; a song several places agree on fits better.
  final byId = <String, AutoCandidate>{};
  final hits = <String, int>{};
  // your favourites and most played only count as such when they fit what's playing; the others are just
  // "anything" (rare), so a quiet sound-alike source doesn't fill the queue with unrelated hearts
  final picky = genres.isNotEmpty || relatedArtists.isNotEmpty;
  bool fitsSeeds(Song s) => genres.contains(s.genre.toLowerCase()) || relatedArtists.contains(artistKey(s));
  for (var c in candidates) {
    if (picky && (c.source == AutoSource.favourite || c.source == AutoSource.frequent) && !fitsSeeds(c.song)) {
      c = AutoCandidate(c.song, AutoSource.anything, c.rank);
    }
    final s = c.song;
    if (s.id.isEmpty || (s.isLookup && !allowLookup) || isPodcastId(s.id) || exclude.contains(s.id)) continue;
    if (notForMe().blocks(s)) continue; // you said not to suggest it (not_for_me.dart)
    if (recentKeys.contains(songKey(s)) || st.skipsALot(s.id) || s.userRating == 1) continue;
    hits[s.id] = (hits[s.id] ?? 0) + 1;
    final had = byId[s.id];
    if (had == null || (weights[c.source] ?? 0) > (weights[had.source] ?? 0)) byId[s.id] = c;
  }

  double score(AutoCandidate c) {
    final s = c.song;
    var x = 1 / (1 + c.rank * 0.12); // the source's own order
    x += 0.3 * ((hits[s.id] ?? 1) - 1);
    if (s.starred) x += 0.4;
    x += switch (s.userRating) { 5 => 0.5, 4 => 0.3, 2 => -0.4, _ => 0.0 };
    x -= 0.6 * st.skipShare(s.id);
    if ((c.source == AutoSource.favourite || c.source == AutoSource.frequent) && fitsSeeds(s)) x += 0.6;
    return x + r.nextDouble() * 0.35; // a little chance, so the same seed doesn't always give the same songs
  }

  final pools = <AutoSource, List<AutoCandidate>>{};
  final scores = {for (final c in byId.values) c.song.id: score(c)};
  for (final c in byId.values) {
    (pools[c.source] ??= []).add(c);
  }
  for (final l in pools.values) {
    l.sort((a, b) => scores[b.song.id]!.compareTo(scores[a.song.id]!));
  }

  final tail = [for (final s in recent) artistKey(s)]; // artists in play order, newest last
  final out = <AutoCandidate>[];
  final keys = <String>{};

  bool fits(AutoCandidate c, int level) {
    if (keys.contains(songKey(c.song))) return false;
    if (level >= 2) return true;
    final a = artistKey(c.song);
    final gap = level == 0 ? artistGap : 1; // relaxed: just not twice in a row
    if (tail.reversed.take(gap).contains(a)) return false;
    return level == 1 || tail.reversed.take(10).where((x) => x == a).length < maxPerArtist;
  }

  while (out.length < n) {
    AutoCandidate? chosen;
    for (var level = 0; level < 3 && chosen == null; level++) {
      // the kinds that still have a song that fits, then one of them by weight
      final open = <AutoSource, AutoCandidate>{};
      for (final e in pools.entries) {
        final c = e.value.where((c) => fits(c, level)).firstOrNull;
        if (c != null && (weights[e.key] ?? 0) > 0) open[e.key] = c;
      }
      if (open.isEmpty) continue;
      final total = open.keys.fold<double>(0, (t, k) => t + weights[k]!);
      var at = r.nextDouble() * total;
      for (final e in open.entries) {
        at -= weights[e.key]!;
        if (at <= 0) {
          chosen = e.value;
          break;
        }
      }
      chosen ??= open.values.last;
    }
    if (chosen == null) break; // nothing left
    pools[chosen.source]!.remove(chosen);
    out.add(chosen);
    keys.add(songKey(chosen.song));
    tail.add(artistKey(chosen.song));
  }
  return out;
}
