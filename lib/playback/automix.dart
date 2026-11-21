/// Automix: smart transitions. The server measures each song (music-lookup's mix-analyzer): where its sound
/// starts and ends, where its outro (fade-out) starts and its tempo. With that, the next song comes in where
/// this one starts to fade instead of a fixed number of seconds before the end, the blend lasts a few bars at
/// the song's tempo, trailing silence is cut, and the next song's silent start is skipped. Without it, the
/// plain crossfade setting is used.
library;

/// What the server measured for one song (seconds from its start).
class MixInfo {
  const MixInfo({this.start = 0, this.introEnd, this.outroStart, this.end, this.bpm, this.beat, this.dur});
  final double start;
  final double? introEnd, outroStart, end, bpm, beat, dur;

  static double? _d(Object? v) => v is num ? v.toDouble() : null;

  factory MixInfo.fromJson(Map<String, dynamic> j) => MixInfo(
    start: _d(j['start']) ?? 0,
    introEnd: _d(j['introEnd']),
    outroStart: _d(j['outroStart']),
    end: _d(j['end']),
    bpm: _d(j['bpm']),
    beat: _d(j['beat']),
    dur: _d(j['dur']),
  );
}

/// A planned transition: at [fadeAt] in the playing song the next one starts (at [nextStart]) and the two
/// blend over [length]; when that's done before the playing song ends, playback moves on to the next one.
class Transition {
  const Transition(this.fadeAt, this.length, {this.nextStart = Duration.zero, this.nextSpeed = 1});
  final Duration fadeAt, length, nextStart;
  /// Beat-matched: the next song starts at this speed (the playing song's tempo, pitch kept) and eases back to
  /// its own over the blend; its start is set so its beats land on the playing song's.
  final double nextSpeed;

  @override
  String toString() => 'Transition(at $fadeAt, $length, next from $nextStart at ${nextSpeed}x)';
}

/// How close two tempos must be to match them (6%: more sounds like a different song).
const beatMatchRange = 0.06;

/// (speed for the next song, where it starts) so that its beats fall on the playing song's from [fadeAt],
/// or null when the tempos are too far apart or not known. [nominal]: where it would start anyway.
(double, Duration)? beatMatch(MixInfo a, MixInfo b, Duration fadeAt, Duration nominal) {
  final ba = a.bpm, bb = b.bpm, beatA = a.beat, beatB = b.beat;
  if (ba == null || bb == null || beatA == null || beatB == null || ba <= 0 || bb <= 0) return null;
  final speed = ba / bb;
  if ((speed - 1).abs() > beatMatchRange) return null;
  final at = fadeAt.inMicroseconds / 1e6, from = nominal.inMicroseconds / 1e6;
  final periodA = 60 / ba, periodB = 60 / bb;
  // the playing song's next beat after the blend starts, and how long until it (real time)
  final tA = beatA + ((at - beatA) / periodA).ceil() * periodA;
  final wait = tA - at;
  // the next song moves `speed` seconds of its own per second: its beat must be there after `wait`
  final reach = from + wait * speed;
  final beat = beatB + ((reach - beatB) / periodB).ceil() * periodB;
  final start = beat - wait * speed;
  return (speed, Duration(microseconds: (start * 1e6).round()));
}

Duration _s(double s) => Duration(milliseconds: (s * 1000).round());

/// How long a blend lasts at this tempo: 4 bars (16 beats), 2–12 s; 6 s when the tempo isn't known.
Duration blendLength(double? bpm) {
  if (bpm == null || bpm < 40 || bpm > 250) return const Duration(seconds: 6);
  return _s((16 * 60 / bpm).clamp(2.0, 12.0));
}

/// The transition from the playing song (measured [a], [length] long) into the next one ([b]).
/// [automix] off, or [a] not measured: the plain crossfade of [crossfade] seconds (null when that's 0).
Transition? planTransition({
  required Duration length,
  MixInfo? a,
  MixInfo? b,
  bool automix = true,
  int crossfade = 0,
}) {
  // the next song's silent start is skipped (not a quiet intro: only up to where its sound starts)
  final nextStart = automix && b != null && b.start > 0.2 && b.start < 12 ? _s(b.start) : Duration.zero;
  Transition? plain() => crossfade <= 0
      ? null
      : Transition(length - Duration(seconds: crossfade), Duration(seconds: crossfade), nextStart: nextStart);
  if (!automix || a == null || a.end == null || length <= const Duration(seconds: 20)) return plain();
  // where the sound really ends (trailing silence cut), at most the song's length
  final end = _s(a.end! + 0.25) < length ? _s(a.end! + 0.25) : length;
  final outroStart = _s(a.outroStart ?? a.end!);
  final outro = end - outroStart;
  final bars = blendLength(a.bpm);
  Duration at, blend;
  if (outro >= const Duration(seconds: 2)) {
    // a fade-out or outro: the next song comes in as it begins and is fully there within a few bars
    at = outroStart;
    blend = outro < bars ? outro : bars;
  } else {
    // a song that stops: a short blend right at its end, so its last notes aren't drowned
    blend = const Duration(seconds: 2);
    at = end - blend;
  }
  if (at < length ~/ 2) return plain(); // not a believable outro (half the song): plain crossfade
  final m = b == null ? null : beatMatch(a, b, at, nextStart);
  if (m != null) return Transition(at, blend, nextStart: m.$2, nextSpeed: m.$1);
  return Transition(at, blend, nextStart: nextStart);
}
