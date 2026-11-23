import 'dart:math';

import 'package:encore_core/core/settings.dart';
import 'package:encore_core/data/models.dart';
import 'package:encore_core/playback/levelling.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(String id, String album, ReplayGain rg) => Song(id: id, title: id, albumId: album, replayGain: rg);

/// The dB a peak allows: never past full scale.
double room(double peak) => -20 * log(peak) / ln10;

void main() {
  const auto = ReplayGainMode.auto, track = ReplayGainMode.track, album = ReplayGainMode.album, off = ReplayGainMode.off;

  test('the replayGain object from the server: tags, or what Conductor measured', () {
    final rg = ReplayGain.fromJson({'trackGain': -9.7, 'trackPeak': 0.98, 'albumGain': -8.12, 'albumPeak': 1.02});
    expect([rg.trackGain, rg.trackPeak, rg.albumGain, rg.albumPeak], [-9.7, 0.98, -8.12, 1.02]);
    // as Navidrome and Conductor send a song with nothing known: an empty object
    final none = ReplayGain.fromJson({});
    expect([none.trackGain, none.albumGain], [null, null]);
    expect(replayGainDb([song('a', 'x', none)], 0, auto, 0), isNull);
  });

  test('only a track gain: used in every mode', () {
    final s = [song('a', 'x', const ReplayGain(trackGain: -6, trackPeak: 0.9))];
    for (final m in [track, album, auto]) {
      expect(replayGainDb(s, 0, m, 0), -6, reason: '$m');
    }
    expect(replayGainDb(s, 0, off, 0), isNull);
  });

  test('only an album gain: used in every mode', () {
    final s = [song('a', 'x', const ReplayGain(albumGain: -4, albumPeak: 0.9))];
    for (final m in [track, album, auto]) {
      expect(replayGainDb(s, 0, m, 0), -4, reason: '$m');
    }
  });

  test('both: track or album by the mode; auto takes the album when the queue plays it in order', () {
    const a = ReplayGain(trackGain: -8, trackPeak: 0.5, albumGain: -5, albumPeak: 0.6);
    const b = ReplayGain(trackGain: -2, trackPeak: 0.5, albumGain: -5, albumPeak: 0.6);
    final inOrder = [song('a', 'x', a), song('b', 'x', b)];
    expect(replayGainDb(inOrder, 0, track, 0), -8);
    expect(replayGainDb(inOrder, 1, track, 0), -2);
    expect(replayGainDb(inOrder, 0, album, 0), -5);
    expect(replayGainDb(inOrder, 0, auto, 0), -5, reason: 'next one from the same album');
    expect(replayGainDb(inOrder, 1, auto, 0), -5, reason: 'previous one from the same album');
    final mixed = [song('a', 'x', a), song('c', 'y', b)];
    expect(replayGainDb(mixed, 0, auto, 0), -8, reason: 'shuffled: its own gain');
    expect(replayGainDb(mixed, 1, auto, 0), -2);
    // songs without an album (a podcast, a file from the phone) aren't an album together
    final loose = [song('a', '', a), song('b', '', b)];
    expect(replayGainDb(loose, 0, auto, 0), -8);
  });

  test('never past full scale: a quiet song is turned up only as far as its peak allows', () {
    // a quiet song (+15 dB measured) whose peak is at a quarter of full scale: +12 dB at most
    final s = [song('a', 'x', const ReplayGain(trackGain: 15, trackPeak: 0.25))];
    expect(replayGainDb(s, 0, track, 0), closeTo(room(0.25), 1e-9));
    expect(room(0.25), closeTo(12.04, 0.01));
    // within its room: all of it
    expect(replayGainDb([song('a', 'x', const ReplayGain(trackGain: 3, trackPeak: 0.25))], 0, track, 0), 3);
    // no peak known (or a nonsense one): never louder than it is, quieter as much as it says
    expect(replayGainDb([song('a', 'x', const ReplayGain(trackGain: 4))], 0, track, 0), 0);
    expect(replayGainDb([song('a', 'x', const ReplayGain(trackGain: 4, trackPeak: 0))], 0, track, 0), 0);
    expect(replayGainDb([song('a', 'x', const ReplayGain(trackGain: -4))], 0, track, 0), -4);
    // a peak over full scale (a loud master, measured): turned down at least that far
    expect(replayGainDb([song('a', 'x', const ReplayGain(trackGain: 1, trackPeak: 1.2))], 0, track, 0), closeTo(room(1.2), 1e-9));
    // album mode goes by the album's peak, the track's when there's none
    const rg = ReplayGain(trackGain: 2, trackPeak: 0.3, albumGain: 9, albumPeak: 0.5);
    expect(replayGainDb([song('a', 'x', rg)], 0, album, 0), closeTo(room(0.5), 1e-9));
    const noAlbumPeak = ReplayGain(trackGain: 2, trackPeak: 0.3, albumGain: 12);
    expect(replayGainDb([song('a', 'x', noAlbumPeak)], 0, album, 0), closeTo(room(0.3), 1e-9));
  });

  test('the pre-amp is added, still within the peak', () {
    final s = [song('a', 'x', const ReplayGain(trackGain: 3, trackPeak: 0.5))];
    expect(replayGainDb(s, 0, track, -3), 0);
    expect(replayGainDb(s, 0, track, 2), 5);
    expect(replayGainDb(s, 0, track, 10), closeTo(room(0.5), 1e-9));
  });

  test('as a volume', () {
    expect(dbToVolume(0), 1);
    expect(dbToVolume(-6.0206), closeTo(0.5, 1e-4));
    expect(dbToVolume(-20), closeTo(0.1, 1e-9));
  });
}
