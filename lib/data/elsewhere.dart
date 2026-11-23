import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';
import 'devices.dart';
import 'events.dart';
import 'library.dart' show offlineProvider;
import 'models.dart';
import 'subsonic.dart';

/// "Now playing elsewhere" on Home: what your other devices are playing (from the devices list, which keeps itself
/// fresh), and what other people on the server are listening to, when the server shares it (getNowPlaying: on
/// Conductor and Navidrome everyone on the server sees it there; a server that doesn't answer it shows no one).
///
/// Other people are asked for again when the event stream says `nowPlaying` (a moment later, so a burst of
/// changes is one look), and slowly otherwise: every [elsewherePollEvery] with no stream, and every
/// [elsewhereSafetyNet] with one (an app that just stops is dropped from the server's list after 15 minutes, and no
/// event says so).

/// Someone else's song, as getNowPlaying lists it.
class NowPlayingEntry {
  const NowPlayingEntry(this.song, this.user, this.player, this.minutesAgo);
  final Song song;
  final String user, player; // player: the app it's playing in, as it calls itself
  final int minutesAgo;

  static NowPlayingEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j.cast<String, dynamic>();
    final song = Song.fromJson(m);
    if (song.id.isEmpty) return null;
    final ago = m['minutesAgo'];
    return NowPlayingEntry(
      song,
      '${m['username'] ?? ''}',
      '${m['playerName'] ?? ''}',
      ago is num ? ago.toInt() : int.tryParse('$ago') ?? 0,
    );
  }
}

extension NowPlayingCalls on SubsonicClient {
  /// What everyone on the server is playing (the server's own rules say who's shown).
  Future<List<NowPlayingEntry>> nowPlaying() async {
    final r = await call('getNowPlaying');
    final np = r['nowPlaying'];
    final list = np is Map ? np['entry'] : null;
    return [for (final e in (list is List ? list : const [])) ?NowPlayingEntry.fromJson(e)];
  }
}

/// With no event stream: how often other people are looked at while Home is shown.
const elsewherePollEvery = Duration(seconds: 90);

/// With the event stream: looked at this often anyway.
const elsewhereSafetyNet = Duration(minutes: 5);

/// An event's look waits this long, so several changes at once are one call.
const elsewhereSettle = Duration(milliseconds: 800);

/// Other people at most this many (the newest first).
const elsewhereMaxPeople = 8;

/// The other people on the server and what they're playing (not you: your devices come from the devices list).
/// Empty when signed out, offline, or the server doesn't say.
class OthersPlayingNotifier extends AsyncNotifier<List<NowPlayingEntry>> {
  bool _loading = false, _again = false;
  Timer? _settle;
  DateTime _lastLook = DateTime.now();

  @override
  Future<List<NowPlayingEntry>> build() async {
    final c = ref.watch(clientProvider);
    if (c == null || ref.watch(offlineProvider)) return const [];
    final live = ref.watch(liveEventsProvider);
    bool told() => live != null && live.healthy && live.serverEvents.contains('nowPlaying');
    final sub = live?.events.listen((e) {
      if (e.type != 'nowPlaying' && e.type != 'resync') return;
      _settle?.cancel();
      _settle = Timer(elsewhereSettle, () => unawaited(refresh()));
    });
    _lastLook = DateTime.now();
    final timer = Timer.periodic(elsewherePollEvery, (_) {
      // (the safety net counted from the last look)
      if (!told() || DateTime.now().difference(_lastLook) >= elsewhereSafetyNet) unawaited(refresh());
    });
    ref.onDispose(() {
      sub?.cancel();
      timer.cancel();
      _settle?.cancel();
    });
    return _load(c);
  }

  static Future<List<NowPlayingEntry>> _load(SubsonicClient c) async {
    List<NowPlayingEntry> all;
    try {
      all = await c.nowPlaying();
    } on SubsonicException {
      return const []; // not shared here (or not a call this server has)
    }
    final me = c.creds.username.toLowerCase();
    final seen = <String>{};
    final out = <NowPlayingEntry>[];
    for (final e in all..sort((a, b) => a.minutesAgo.compareTo(b.minutesAgo))) {
      if (e.user.toLowerCase() == me || e.user.isEmpty) continue;
      if (!seen.add('${e.user.toLowerCase()}|${e.player}')) continue; // one per person's app: its newest
      out.add(e);
    }
    return out.take(elsewhereMaxPeople).toList();
  }

  /// Look again (an event, the timer, pull to refresh). What's shown stays while it's asked, and when it fails.
  Future<void> refresh() async {
    final c = ref.read(clientProvider);
    if (c == null || ref.read(offlineProvider)) return;
    if (_loading) {
      _again = true;
      return;
    }
    _loading = true;
    try {
      do {
        _again = false;
        _lastLook = DateTime.now();
        final v = await _load(c);
        if (!ref.mounted) return;
        state = AsyncData(v);
      } while (_again);
    } catch (_) {
      // offline for a moment: what was shown stays
    } finally {
      _loading = false;
    }
  }
}

final othersPlayingProvider = AsyncNotifierProvider.autoDispose<OthersPlayingNotifier, List<NowPlayingEntry>>(
  OthersPlayingNotifier.new,
);

/// One thing playing elsewhere: on one of your devices ([device]), or someone else's ([person]).
class PlayingElsewhere {
  const PlayingElsewhere.device(RemoteDevice this.device, this.song) : person = null;
  const PlayingElsewhere.person(NowPlayingEntry this.person, this.song) : device = null;
  final RemoteDevice? device;
  final NowPlayingEntry? person;
  final Song song;

  bool get mine => device != null;

  /// Where (one of yours) or who (someone else, and their app when it says).
  String get where => device != null
      ? device!.name
      : (person!.player.isEmpty ? person!.user : '${person!.user} · ${person!.player}');

  /// What a screen reader says for it.
  String get spoken {
    final by = song.artist.isEmpty ? '' : ' by ${song.artist}';
    return device != null ? '${song.title}$by, playing on your ${device!.name}' : '${person!.user} is listening to ${song.title}$by';
  }
}

/// Your devices first (the ones playing now), then other people; empty when nothing plays elsewhere.
final playingElsewhereProvider = Provider.autoDispose<List<PlayingElsewhere>>((ref) {
  final devices = ref.watch(devicesProvider.select((s) => s.devices));
  final others = ref.watch(othersPlayingProvider).value ?? const <NowPlayingEntry>[];
  return [
    for (final d in devices)
      if (d.online && d.state.playing && d.state.hasSong)
        PlayingElsewhere.device(
          d,
          Song(
            id: d.state.songId,
            title: d.state.title,
            artist: d.state.artist,
            album: d.state.album,
            coverArt: d.state.coverArt,
            duration: d.state.durationMs ~/ 1000,
          ),
        ),
    for (final p in others) PlayingElsewhere.person(p, p.song),
  ];
});
