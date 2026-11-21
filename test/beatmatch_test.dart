import 'package:encore/playback/automix.dart';
import 'package:flutter_test/flutter_test.dart';

double sec(Duration d) => d.inMicroseconds / 1e6;

void main() {
  test('close tempos: the next song plays at the first one\'s speed, beat on beat', () {
    const a = MixInfo(outroStart: 200, end: 210, bpm: 120, beat: 0.25); // beats at 0.25 + k·0.5
    const b = MixInfo(start: 0.4, bpm: 124, beat: 0.6); // beats at 0.6 + m·(60/124)
    final m = beatMatch(a, b, const Duration(milliseconds: 200100), const Duration(milliseconds: 400))!;
    expect(m.$1, closeTo(120 / 124, 1e-9));
    // A's next beat after 200.1 s is 200.25 s: 0.15 s later. B must be on one of its beats then.
    final bAtBeat = sec(m.$2) + 0.15 * m.$1;
    final k = (bAtBeat - 0.6) / (60 / 124);
    expect((k - k.round()).abs(), lessThan(1e-6));
    expect(sec(m.$2), greaterThanOrEqualTo(0.4)); // never before its silent start ends
  });

  test('tempos too far apart, or not measured: no match', () {
    const a = MixInfo(bpm: 120, beat: 0.1), b = MixInfo(bpm: 140, beat: 0.2);
    expect(beatMatch(a, b, const Duration(seconds: 100), Duration.zero), isNull);
    expect(beatMatch(const MixInfo(bpm: 120), const MixInfo(bpm: 121, beat: 0), const Duration(seconds: 1), Duration.zero), isNull);
  });

  test('the plan carries the speed', () {
    final t = planTransition(
      length: const Duration(seconds: 212),
      a: const MixInfo(outroStart: 200, end: 210, bpm: 120, beat: 0.25),
      b: const MixInfo(start: 0.4, bpm: 118, beat: 0.5),
    )!;
    expect(t.nextSpeed, closeTo(120 / 118, 1e-9));
    final far = planTransition(
      length: const Duration(seconds: 212),
      a: const MixInfo(outroStart: 200, end: 210, bpm: 120, beat: 0.25),
      b: const MixInfo(start: 0.4, bpm: 90, beat: 0.5),
    )!;
    expect(far.nextSpeed, 1);
    expect(far.nextStart, const Duration(milliseconds: 400));
  });
}
