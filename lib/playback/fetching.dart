import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;

import '../data/models.dart';
import '../data/subsonic.dart';

/// Songs you don't have, being got "on trial" by your server (music-lookup) because you played or queued them,
/// or autoplay / a radio picked them. Each one is asked for once; then how they're going is checked every few
/// seconds until each is there, can't be had, or has taken too long to keep checking (the server carries on,
/// and it turns up in the "On trial" playlist if it comes).
class SongFetcher {
  SongFetcher({
    required this.ask,
    this.fast = const Duration(seconds: 4),
    this.slow = const Duration(seconds: 15),
    this.fastFor = const Duration(minutes: 1),
    this.giveUpAfter = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// Asks the server about these songs (and to get the ones it hasn't got yet).
  final Future<LookupReport> Function(List<String> ids) ask;
  final Duration fast, slow, fastFor, giveUpAfter;
  final DateTime Function() _now;

  /// A song's status changed.
  void Function(FetchInfo f)? onChange;

  /// The server's song finder can't be reached (said once until it answers again).
  void Function()? onUnreachable;

  final Map<String, FetchInfo> _info = {};
  final Map<String, DateTime> _since = {}; // when each was first asked for
  /// The server's last answer: how long songs stay on trial, the daily limit (null until it has answered).
  final ValueNotifier<LookupReport?> rulesNow = ValueNotifier(null);
  LookupReport? get rules => rulesNow.value;
  bool unreachable = false;
  int _failures = 0;
  Timer? _timer;
  bool _busy = false;

  FetchInfo? operator [](String id) => _info[id];

  /// Still checking on these (asked for, not there yet, not given up on).
  List<String> get watching => [
    for (final e in _since.entries)
      if (_now().difference(e.value) < giveUpAfter && (_info[e.key]?.pending ?? true)) e.key,
  ];

  /// Start getting these songs you don't have (ids that aren't songs you don't have, or are already being
  /// got, are left alone).
  Future<void> want(Iterable<String> ids) async {
    final fresh = [
      for (final id in ids.toSet())
        if (id.startsWith('dz-t-') && !_since.containsKey(id)) id,
    ];
    if (fresh.isEmpty) return;
    final t = _now();
    for (final id in fresh) {
      _since[id] = t;
    }
    await check();
  }

  /// Ask about every song still being got (also the timer's job).
  Future<void> check() async {
    if (_busy) return;
    final ids = watching;
    if (ids.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _busy = true;
    try {
      final r = await ask(ids);
      rulesNow.value = r;
      _failures = 0;
      unreachable = false;
      for (final f in r.songs) {
        final was = _info[f.id];
        _info[f.id] = f;
        if (was == null || was.status != f.status || was.songId != f.songId) onChange?.call(f);
      }
    } catch (e) {
      _failures++;
      // the server doesn't know the request (music-lookup isn't in front of it) or keeps not answering
      final missing = e is SubsonicException && (e.code == 70 || e.message.contains('404'));
      if ((missing || _failures >= 3) && !unreachable) {
        unreachable = true;
        onUnreachable?.call();
      }
    } finally {
      _busy = false;
    }
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final ids = watching;
    if (ids.isEmpty) return;
    final newest = ids.map((id) => _since[id]!).reduce((a, b) => a.isAfter(b) ? a : b);
    final soon = !unreachable && _now().difference(newest) < fastFor;
    _timer = Timer(unreachable ? const Duration(seconds: 30) : (soon ? fast : slow), check);
  }

  /// Ask the server for its rules about songs on trial (for Settings), once.
  Future<void> loadRules() async {
    if (rules != null) return;
    try {
      rulesNow.value = await ask(const []);
    } catch (_) {}
  }

  /// Forget everything (a new server, or the setting was switched off).
  void reset() {
    _timer?.cancel();
    _timer = null;
    _info.clear();
    _since.clear();
    _failures = 0;
    unreachable = false;
  }
}

/// What happens to songs you don't have when they're got automatically, in plain words.
String trialRules(LookupReport? r) {
  final h = r?.trialHours ?? 24, n = r?.perDay ?? 40;
  final hours = h == 24 ? 'a day' : (h == 1 ? 'an hour' : '${h == h.roundToDouble() ? h.toInt() : h} hours');
  return 'Audition: playing or queueing a song you don\'t have gets it into your "On trial" playlist. Heart it (or add it '
      'to a playlist) to keep it for good; the rest are deleted $hours after they arrive. Up to $n new songs a '
      'day. Off: you\'re asked first.';
}
