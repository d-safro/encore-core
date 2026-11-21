import 'package:encore/core/settings.dart';
import 'package:encore/playback/automix.dart';
import 'package:flutter_test/flutter_test.dart';

Duration s(num x) => Duration(milliseconds: (x * 1000).round());

void main() {
  const len = Duration(seconds: 212);

  test('a fade-out: the next song comes in as it begins, for a few bars', () {
    const a = MixInfo(start: 0.3, outroStart: 200, end: 211.5, bpm: 120); // 11.5 s fade
    final t = planTransition(length: len, a: a, b: const MixInfo(start: 1.2))!;
    expect(t.fadeAt, s(200));
    expect(t.length, s(8)); // 4 bars at 120 BPM, shorter than the outro
    expect(t.nextStart, s(1.2)); // its silent start skipped
  });

  test('a short fade: the blend lasts the fade', () {
    const a = MixInfo(outroStart: 207.7, end: 212.0, bpm: 123);
    final t = planTransition(length: len, a: a)!;
    expect(t.fadeAt, s(207.7));
    expect(t.length.inMilliseconds, closeTo(4300, 20)); // to where the song ends
  });

  test('a song that stops dead: 2 s at its very end, trailing silence cut', () {
    const a = MixInfo(outroStart: 199.8, end: 200.0, bpm: 140); // then 12 s of silence
    final t = planTransition(length: len, a: a)!;
    expect(t.fadeAt, s(198.25));
    expect(t.length, s(2));
  });

  test('tempo sets the blend: 2–12 s, 6 s when unknown', () {
    expect(blendLength(60), s(12));
    expect(blendLength(120), s(8));
    expect(blendLength(240), s(4));
    expect(blendLength(null), s(6));
    expect(blendLength(900), s(6));
  });

  test('not measured: the plain crossfade, or none', () {
    final t = planTransition(length: len, crossfade: 6)!;
    expect(t.fadeAt, len - s(6));
    expect(t.length, s(6));
    expect(planTransition(length: len), isNull);
    // Automix off: the crossfade, measured or not, but still no silent start skipping
    final off = planTransition(length: len, a: const MixInfo(outroStart: 150, end: 200), b: const MixInfo(start: 2),
        automix: false, crossfade: 4)!;
    expect(off.fadeAt, len - s(4));
    expect(off.nextStart, Duration.zero);
  });

  test('an "outro" over half the song is not believed', () {
    const quiet = MixInfo(outroStart: 60, end: 210);
    expect(planTransition(length: len, a: quiet, crossfade: 5)!.fadeAt, len - s(5));
    expect(planTransition(length: len, a: quiet), isNull);
  });

  test('a long silent start is a quiet intro, not skipped', () {
    final t = planTransition(length: len, a: const MixInfo(outroStart: 205, end: 211), b: const MixInfo(start: 30))!;
    expect(t.nextStart, Duration.zero);
  });

  test('reads the server answer', () {
    final m = MixInfo.fromJson({'start': 0.5, 'outroStart': 200, 'end': 205.2, 'bpm': 120, 'beat': 0.7});
    expect(m.end, 205.2);
    expect(m.introEnd, isNull);
  });

  test('the setting is saved, off by default', () {
    expect(const Settings().automix, isFalse);
    expect(Settings.fromJson(const Settings(automix: true).toJson()).automix, isTrue);
  });
}
