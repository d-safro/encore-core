import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Private session: while it's on, what you play isn't recorded anywhere. Encore sends no scrobbles (so no
/// Navidrome play counts, Last.fm / ListenBrainz or listening stats), no "now playing" report (Discord status,
/// other apps), and autoplay / smart shuffle don't learn from those plays. Plays made offline during it aren't
/// queued for later either.
///
/// It's never saved: it ends when the app restarts, and on its own after [privateSessionLength].
const privateSessionLength = Duration(hours: 6);

/// When the session ends, from when it started (pure, for tests).
DateTime privateSessionEnd(DateTime started) => started.add(privateSessionLength);

/// Whether a session ending at [until] is still on at [now].
bool privateSessionOn(DateTime? until, DateTime now) => until != null && now.isBefore(until);

/// The time the private session ends, or null when it's off.
class PrivateSessionNotifier extends Notifier<DateTime?> {
  Timer? _timer;

  @override
  DateTime? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  bool get on => privateSessionOn(state, DateTime.now());

  void set(bool v) {
    _timer?.cancel();
    if (!v) {
      state = null;
      return;
    }
    state = privateSessionEnd(DateTime.now());
    _timer = Timer(privateSessionLength, () => state = null);
  }

  void toggle() => set(!on);
}

final privateSessionProvider = NotifierProvider<PrivateSessionNotifier, DateTime?>(PrivateSessionNotifier.new);

/// "Private until 21:40" for the switches' subtitles.
String privateSessionLabel(DateTime? until) {
  if (until == null) return 'Plays aren\'t counted or shared. Turns off after 6 hours or when Encore restarts';
  final h = until.hour.toString().padLeft(2, '0'), m = until.minute.toString().padLeft(2, '0');
  return 'On until $h:$m: plays aren\'t counted, scrobbled or shown as now playing';
}
