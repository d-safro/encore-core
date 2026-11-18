import 'dart:math';

import 'package:encore/core/settings.dart';
import 'package:encore/data/models.dart';
import 'package:encore/playback/autoplay.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(String id, {String? artist, String title = '', String genre = '', bool starred = false, int? rating}) =>
    Song(
      id: id,
      title: title.isEmpty ? 'Song $id' : title,
      artist: artist ?? 'Artist $id',
      genre: genre,
      starred: starred,
      userRating: rating,
    );

List<AutoCandidate> from(AutoSource source, List<Song> songs) => [
  for (final (k, s) in songs.indexed) AutoCandidate(s, source, k),
];

void main() {
  group('autoplay picks', () {
    test('never repeats a song: not one just played, not one in the queue, not twice in one go', () {
      final played = song('a');
      final cands = [
        ...from(AutoSource.soundAlike, [played, song('b'), song('c'), song('b')]),
        ...from(AutoSource.genre, [song('c'), song('d'), song('e')]),
      ];
      final picks = pickAutoplay(candidates: cands, n: 10, recent: [played], exclude: {'e'}, rng: Random(1));
      final ids = picks.map((p) => p.song.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids, isNot(contains('a')));
      expect(ids, isNot(contains('e')));
      expect(ids.toSet(), {'b', 'c', 'd'});
    });

    test('the same recording on another album counts as a repeat', () {
      final played = song('a', artist: 'Nina', title: 'Sinnerman');
      final cands = from(AutoSource.soundAlike, [
        song('a2', artist: 'Nina', title: 'Sinnerman (Remastered)'),
        song('a3', artist: 'Nina feat. Someone', title: 'Sinnerman [Live]'),
        song('b', artist: 'Other', title: 'Something else'),
      ]);
      final picks = pickAutoplay(candidates: cands, n: 5, recent: [played], rng: Random(2));
      expect(picks.map((p) => p.song.id), ['b']);
    });

    test('the same recording played earlier (before a restart) is a repeat too', () {
      final cands = from(AutoSource.soundAlike, [
        song('c1', artist: 'Blue Harbor', title: 'Blue Song 1 (Remastered)'),
        song('b', artist: 'Other', title: 'Fresh'),
      ]);
      final picks = pickAutoplay(candidates: cands, n: 5, excludeKeys: {'blue harbor|blue song 1'}, rng: Random(7));
      expect(picks.map((p) => p.song.id), ['b']);
    });

    test('spreads artists out: never the same artist within four songs, at most two in ten', () {
      final cands = <AutoCandidate>[];
      for (var a = 0; a < 6; a++) {
        cands.addAll(from(AutoSource.soundAlike, [for (var k = 0; k < 6; k++) song('$a-$k', artist: 'Band $a')]));
      }
      for (var seed = 0; seed < 20; seed++) {
        final picks = pickAutoplay(candidates: cands, n: 10, rng: Random(seed));
        expect(picks.length, 10);
        final artists = picks.map((p) => p.song.artist).toList();
        for (var i = 0; i < artists.length; i++) {
          final window = artists.sublist(max(0, i - 4), i);
          expect(window, isNot(contains(artists[i])), reason: 'seed $seed: $artists');
        }
        for (final a in artists.toSet()) {
          expect(artists.where((x) => x == a).length, lessThanOrEqualTo(2), reason: 'seed $seed: $artists');
        }
      }
    });

    test('artists just played count toward the spread', () {
      final recent = [song('r1', artist: 'Band A')];
      final cands = from(AutoSource.soundAlike, [
        song('x1', artist: 'Band A'),
        song('x2', artist: 'Band A'),
        song('y1', artist: 'Band B'),
      ]);
      final picks = pickAutoplay(candidates: cands, n: 1, recent: recent, rng: Random(3));
      expect(picks.single.song.artist, 'Band B');
    });

    test('when only one artist is left in what fits, something else fills in rather than that artist again', () {
      for (var seed = 0; seed < 20; seed++) {
        final cands = [
          ...from(AutoSource.genre, [for (var k = 0; k < 6; k++) song('v$k', artist: 'Vector')]),
          ...from(AutoSource.anything, [for (var k = 0; k < 6; k++) song('a$k', artist: 'Other $k')]),
        ];
        final picks = pickAutoplay(candidates: cands, n: 5, recent: [song('r', artist: 'Pulse')], rng: Random(seed));
        final artists = picks.map((p) => p.song.artist).toList();
        for (var i = 1; i < artists.length; i++) {
          expect(artists[i], isNot(artists[i - 1]), reason: 'seed $seed: $artists');
        }
        expect(artists.where((a) => a == 'Vector').length, lessThanOrEqualTo(2), reason: 'seed $seed: $artists');
      }
    });

    test('with only one artist left it still keeps going rather than stopping', () {
      final cands = from(AutoSource.soundAlike, [for (var k = 0; k < 5; k++) song('s$k', artist: 'Solo')]);
      final picks = pickAutoplay(candidates: cands, n: 5, rng: Random(4));
      expect(picks.length, 5);
    });

    test('when AudioMuse has nothing, the other sources fill in', () {
      final cands = [
        ...from(AutoSource.similarArtist, [song('sa1'), song('sa2')]),
        ...from(AutoSource.genre, [song('g1'), song('g2')]),
        ...from(AutoSource.discovery, [song('d1')]),
      ];
      final picks = pickAutoplay(candidates: cands, n: 5, rng: Random(5));
      expect(picks.length, 5);
      expect(picks.map((p) => p.source).toSet(), {AutoSource.similarArtist, AutoSource.genre, AutoSource.discovery});
    });

    test('with no candidates at all it returns nothing (the caller falls back)', () {
      expect(pickAutoplay(candidates: const [], n: 5), isEmpty);
    });

    test('mixes the sources, most of it sound-alikes, with a little discovery', () {
      final counts = <AutoSource, int>{};
      for (var seed = 0; seed < 200; seed++) {
        final cands = [
          for (final src in AutoSource.values)
            ...from(src, [for (var k = 0; k < 10; k++) song('${src.name}-$k', genre: 'Jazz')]),
        ];
        for (final p in pickAutoplay(candidates: cands, n: 5, seedGenres: {'Jazz'}, rng: Random(seed))) {
          counts[p.source] = (counts[p.source] ?? 0) + 1;
        }
      }
      final total = counts.values.fold(0, (a, b) => a + b);
      double share(AutoSource s) => (counts[s] ?? 0) / total;
      expect(share(AutoSource.soundAlike), greaterThan(0.3));
      expect(share(AutoSource.soundAlike), lessThan(0.55));
      for (final s in AutoSource.values.where((s) => s != AutoSource.anything)) {
        expect(share(s), greaterThan(0.03), reason: '$s is part of the mix');
      }
      expect(share(AutoSource.discovery), lessThan(share(AutoSource.soundAlike) / 3));
      expect(share(AutoSource.anything), lessThan(0.05), reason: 'only now and then');
    });

    test('leaves out songs you skip a lot and one-star songs', () {
      final skips = SkipStats();
      for (var k = 0; k < 3; k++) {
        skips.skipped('skipped');
      }
      final cands = from(AutoSource.soundAlike, [song('skipped'), song('hated', rating: 1), song('fine')]);
      final picks = pickAutoplay(candidates: cands, n: 5, skips: skips, rng: Random(6));
      expect(picks.map((p) => p.song.id), ['fine']);
    });

    test('a song you skipped a few times but also play through still comes', () {
      final skips = SkipStats();
      for (var k = 0; k < 3; k++) {
        skips.skipped('mixed');
        skips.played('mixed');
      }
      expect(skips.skipsALot('mixed'), isFalse);
      final picks = pickAutoplay(candidates: from(AutoSource.soundAlike, [song('mixed')]), n: 1, skips: skips);
      expect(picks.single.song.id, 'mixed');
    });

    test('leans on hearts and ratings', () {
      for (var seed = 0; seed < 30; seed++) {
        final cands = from(AutoSource.soundAlike, [
          song('plain'),
          song('loved', starred: true, rating: 5),
        ]);
        final picks = pickAutoplay(candidates: cands, n: 1, rng: Random(seed));
        expect(picks.single.song.id, 'loved');
      }
    });

    test('favourites that do not fit what is playing are only a rare pick', () {
      final counts = <String, int>{};
      for (var seed = 0; seed < 200; seed++) {
        final cands = [
          ...from(AutoSource.similarArtist, [for (var k = 0; k < 10; k++) song('sa$k', genre: 'Rock')]),
          ...from(AutoSource.favourite, [for (var k = 0; k < 10; k++) song('fav$k', genre: 'Bard', starred: true)]),
        ];
        for (final p in pickAutoplay(candidates: cands, n: 5, seedGenres: {'Rock'}, rng: Random(seed))) {
          final k = p.song.id.startsWith('fav') ? 'unrelated favourite' : 'fits';
          counts[k] = (counts[k] ?? 0) + 1;
        }
      }
      expect((counts['unrelated favourite'] ?? 0) / 1000, lessThan(0.15), reason: '$counts');
      expect(counts['fits'], greaterThan(800), reason: '$counts');
    });

    test('favourites that fit what is playing come before ones that do not', () {
      var jazz = 0;
      for (var seed = 0; seed < 100; seed++) {
        final cands = from(AutoSource.favourite, [
          song('metal', genre: 'Metal'),
          song('jazz', genre: 'Jazz'),
        ]);
        final picks = pickAutoplay(candidates: cands, n: 1, seedGenres: {'jazz'}, rng: Random(seed));
        if (picks.single.song.id == 'jazz') jazz++;
      }
      expect(jazz, greaterThan(75));
    });

    test('skips podcast episodes and songs you do not have', () {
      final cands = from(AutoSource.soundAlike, [
        song('pe-1'),
        const Song(id: 'dz-1', title: 'Not here', lookup: LookupState.available),
        song('ok'),
      ]);
      expect(pickAutoplay(candidates: cands, n: 3).map((p) => p.song.id), ['ok']);
    });
  });

  group('autoplay seeds', () {
    test('the latest song always, plus a couple from just before it', () {
      final history = [for (var k = 0; k < 10; k++) song('h$k')];
      for (var seed = 0; seed < 20; seed++) {
        final seeds = chooseSeeds(history, rng: Random(seed));
        expect(seeds.first.id, 'h9');
        expect(seeds.length, 3);
        expect(seeds.map((s) => s.id).toSet().length, 3);
        for (final s in seeds.skip(1)) {
          expect(['h4', 'h5', 'h6', 'h7', 'h8'], contains(s.id), reason: 'from the last few, so it drifts');
        }
      }
    });

    test('a single song seeds from itself; podcasts and missing songs are not seeds', () {
      expect(chooseSeeds([song('only')]).map((s) => s.id), ['only']);
      expect(chooseSeeds([song('a'), song('pe-9')]).map((s) => s.id), ['a']);
      expect(chooseSeeds([song('pe-9')]), isEmpty);
    });

    test('the same song played twice is one seed', () {
      final seeds = chooseSeeds([song('a'), song('b'), song('a')], rng: Random(1));
      expect(seeds.map((s) => s.id).toList(), ['a', 'b']);
    });
  });

  group('skip stats', () {
    test('survive being saved', () {
      final s = SkipStats()
        ..skipped('x')
        ..skipped('x')
        ..played('x')
        ..played('y');
      final back = SkipStats.fromJson(s.toJson());
      expect(back.skips('x'), 2);
      expect(back.plays('x'), 1);
      expect(back.plays('y'), 1);
      expect(back.skipShare('x'), closeTo(2 / 3, 1e-9));
      expect(SkipStats.fromJson('junk').skips('x'), 0);
      expect(SkipStats.fromJson({'x': 'junk'}).skips('x'), 0);
    });
  });

  group('autoplay setting', () {
    test('on by default, and the old "Endless playback" switch (saved off for everyone) does not turn it off', () {
      expect(const Settings().autoplay, isTrue);
      expect(Settings.fromJson({'endlessRadio': false}).autoplay, isTrue);
      expect(Settings.fromJson({'autoplay': false}).autoplay, isFalse);
      expect(Settings.fromJson(const Settings().copyWith({'autoplay': false}).toJson()).autoplay, isFalse);
    });
  });
}
