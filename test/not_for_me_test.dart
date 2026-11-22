import 'dart:math';

import 'package:encore/core/settings.dart';
import 'package:encore/data/models.dart';
import 'package:encore/playback/autoplay.dart';
import 'package:encore/playback/not_for_me.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Song s(String id, String artist) => Song(id: id, title: 'T$id', artist: artist);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('songs and artists are blocked, and can be let back', () async {
    await blockSong(s('1', 'A'));
    await blockArtist('The Band');
    expect(notForMe().blocks(s('1', 'Z')), isTrue);
    expect(notForMe().blocks(s('2', 'the band ')), isTrue); // any case, spaces
    expect(notForMe().blocks(s('3', 'Other')), isFalse);
    await blockSong(s('1', 'A')); // twice: once
    expect(notForMe().songs.length, 1);
    await unblockArtist('THE BAND');
    await unblockSong('1');
    expect(notForMe().blocks(s('2', 'The Band')), isFalse);
    expect(notForMe().blocks(s('1', 'A')), isFalse);
  });

  test('autoplay never picks them', () async {
    await blockArtist('Nope');
    final cands = [
      for (var i = 0; i < 20; i++) AutoCandidate(s('$i', i.isEven ? 'Nope' : 'Artist $i'), AutoSource.genre, i),
    ];
    final picks = pickAutoplay(candidates: cands, n: 8, rng: Random(1));
    expect(picks, isNotEmpty);
    expect(picks.any((c) => c.song.artist == 'Nope'), isFalse);
  });
}
