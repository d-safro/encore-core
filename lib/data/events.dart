import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';
import 'devices.dart' show deviceId;

/// Live updates from the server (Conductor's `encore.events`): one stream of server-sent events tells the app at
/// once what changed for this account (a command for this device, another device playing something else, a guest
/// in the Jam, a setting changed elsewhere, a playlist), so the long-polls and timers can rest. They stay for
/// servers without it (Navidrome, older Conductor) and as a safety net while the stream is down.
///
/// Events are hints: whoever cares fetches what changed with the calls it already makes.

/// One event: its [type] (devices, command, jam, sync, nowPlaying, scan, playlist, resync…; '' for a keep-alive)
/// and its small JSON [data].
class LiveEvent {
  const LiveEvent(this.type, [this.data = const {}, this.id]);
  final String type;
  final Map<String, dynamic> data;
  final String? id; // the stream's last event id so far
  @override
  String toString() => 'LiveEvent($type, $data)';
}

/// Reads `text/event-stream` (the WHATWG rules: `event:`, `data:` lines joined, `id:`, `:` comments; a blank line
/// ends an event). A block with no data (a keep-alive comment, an id alone) comes out as a keep-alive.
Stream<LiveEvent> parseEvents(Stream<List<int>> bytes) {
  String? id;
  var type = '';
  final data = <String>[];
  var any = false;
  // (a plain transformer, not an async* function: cancelling it closes the connection at once)
  return bytes.transform(utf8.decoder).transform(const LineSplitter()).transform(
    StreamTransformer<String, LiveEvent>.fromHandlers(
      handleData: (line, sink) {
        if (line.isEmpty) {
          if (!any) return;
          Map<String, dynamic> payload = const {};
          if (data.isNotEmpty) {
            try {
              final v = jsonDecode(data.join('\n'));
              if (v is Map) payload = v.cast<String, dynamic>();
            } catch (_) {}
          }
          sink.add(LiveEvent(data.isEmpty ? '' : (type.isEmpty ? 'message' : type), payload, id));
          type = '';
          data.clear();
          any = false;
          return;
        }
        any = true;
        if (line.startsWith(':')) return;
        final i = line.indexOf(':');
        final field = i < 0 ? line : line.substring(0, i);
        var value = i < 0 ? '' : line.substring(i + 1);
        if (value.startsWith(' ')) value = value.substring(1);
        switch (field) {
          case 'event':
            type = value;
          case 'data':
            data.add(value);
          case 'id':
            if (!value.contains('\u0000')) id = value;
        }
      },
    ),
  );
}

/// Opens the stream (resuming after [lastEventId] when given): its bytes.
typedef EventConnect = Future<Stream<List<int>>> Function(String? lastEventId);

/// Keeps one event stream open: reconnects with a growing pause when it can't (1 s, 2 s, 4 s… up to a minute),
/// at once after a stream that worked, and resumes where it was. [healthy] while a stream is open and
/// answering (a keep-alive at least every 20 s; nothing for [quietLimit] and it's taken for gone).
class LiveEvents {
  LiveEvents(
    this._connect, {
    this.offered,
    Duration Function(int failures)? backoff,
    this.quietLimit = const Duration(seconds: 50),
  }) : _backoff = backoff ?? defaultBackoff;

  final EventConnect _connect;

  /// Whether the server has the stream (asked once, before the first try); null: just try.
  final Future<bool> Function()? offered;
  final Duration Function(int failures) _backoff;
  final Duration quietLimit;

  static final _rnd = Random();

  /// After [failures] tries that didn't get a stream: up to a minute, a little random so devices don't all come
  /// back at the same moment after the server restarts.
  static Duration defaultBackoff(int failures) {
    if (failures <= 0) return Duration(milliseconds: 500 + _rnd.nextInt(1000));
    final s = min(60, 1 << min(failures - 1, 6));
    return Duration(milliseconds: s * 1000 + _rnd.nextInt(1000));
  }

  final _events = StreamController<LiveEvent>.broadcast();
  final _health = StreamController<bool>.broadcast();

  /// What the server says (keep-alives left out). After a gap that couldn't be resumed, a `resync`: fetch anew.
  Stream<LiveEvent> get events => _events.stream;

  /// [healthy] as it changes.
  Stream<bool> get healthChanges => _health.stream;

  bool healthy = false;

  /// null: not known yet; false: the server has no event stream (then nothing is tried).
  bool? supported;
  String? lastEventId;

  /// How many times a stream was asked for (for the tests).
  int connects = 0;

  bool _started = false, _stopped = false;
  Completer<void>? _cut;
  final _done = Completer<void>();

  void start() {
    if (_started || _stopped) return;
    _started = true;
    unawaited(_run());
  }

  /// Try now, instead of waiting out the pause (the app came back to the front, the network is back).
  void retryNow() {
    if (!healthy) _wake();
  }

  /// The stream ends and isn't opened again.
  Future<void> stop() async {
    _stopped = true;
    _wake();
    if (_started) await _done.future;
    _setHealthy(false);
    await _events.close();
    await _health.close();
  }

  void _wake() {
    final c = _cut;
    if (c != null && !c.isCompleted) c.complete();
  }

  void _setHealthy(bool v) {
    if (healthy == v) return;
    healthy = v;
    if (!_health.isClosed) _health.add(v);
  }

  Future<void> _run() async {
    try {
      final offered = this.offered;
      if (offered != null) {
        var yes = false;
        try {
          yes = await offered();
        } catch (_) {}
        supported = yes;
        if (!yes) return; // an older server or Navidrome: the polls go on as they always did
      }
      supported = true;
      var failures = 0;
      var first = true;
      while (!_stopped) {
        var opened = false;
        try {
          connects++;
          final bytes = await _connect(lastEventId);
          final cut = _cut = Completer<void>();
          // nothing at all (not even a keep-alive) for so long: the connection is taken for gone
          Timer? quiet;
          void heard() {
            quiet?.cancel();
            quiet = Timer(quietLimit, _wake);
          }

          heard();
          final sub = parseEvents(bytes).listen(
            (e) {
              heard();
              if (e.id != null) lastEventId = e.id;
              if (e.type == 'hello') {
                opened = true;
                failures = 0;
                _setHealthy(true);
                // back after a gap that wasn't resumed: what was missed meanwhile is fetched anew
                if (!first && e.data['resumed'] != true) _events.add(LiveEvent('resync', const {}, e.id));
                first = false;
              } else if (e.type.isNotEmpty && !_events.isClosed) {
                _events.add(e);
              }
            },
            onError: (_) => _wake(),
            onDone: _wake,
            cancelOnError: true,
          );
          if (_stopped) _wake();
          await cut.future;
          quiet?.cancel();
          unawaited(sub.cancel());
        } catch (_) {
          // no stream: offline, the server restarting, or it said no (too many open)
        }
        _setHealthy(false);
        if (_stopped) break;
        if (!opened) failures++;
        final wait = _cut = Completer<void>();
        final t = Timer(_backoff(opened ? 0 : failures), _wake);
        await wait.future;
        t.cancel();
      }
    } finally {
      _done.complete();
    }
  }
}

/// The live updates for the signed-in server (null when signed out). Started only when the server lists
/// `encore.events`.
final liveEventsProvider = Provider<LiveEvents?>((ref) {
  final c = ref.watch(clientProvider);
  if (c == null) return null;
  final live = LiveEvents(
    (last) => c.openEvents(device: deviceId(), lastEventId: last),
    offered: () async => (await c.openSubsonicExtensions()).contains('encore.events'),
  );
  ref.onDispose(live.stop);
  live.start();
  return live;
});

/// Playlists changed on the server (by you elsewhere, a friend through a shared link, your mixes): a number that
/// goes up, for the playlist screens to fetch again. Per playlist in [PlaylistChanges.of].
class PlaylistChanges {
  const PlaylistChanges([this.all = 0, this.resyncs = 0, this.byId = const {}]);
  final int all, resyncs;
  final Map<String, int> byId;

  /// Changes to one playlist (and the times everything was to be fetched anew).
  (int, int) of(String id) => (resyncs, byId[id] ?? 0);
}

class PlaylistChangesNotifier extends Notifier<PlaylistChanges> {
  @override
  PlaylistChanges build() {
    final live = ref.watch(liveEventsProvider);
    final sub = live?.events.listen((e) {
      final s = state;
      if (e.type == 'resync') {
        state = PlaylistChanges(s.all + 1, s.resyncs + 1, s.byId);
      } else if (e.type == 'playlist') {
        final id = '${e.data['id'] ?? ''}';
        state = PlaylistChanges(s.all + 1, s.resyncs, {...s.byId, id: (s.byId[id] ?? 0) + 1});
      }
    });
    ref.onDispose(() => sub?.cancel());
    return const PlaylistChanges();
  }
}

final playlistChangesProvider = NotifierProvider<PlaylistChangesNotifier, PlaylistChanges>(PlaylistChangesNotifier.new);

/// For the loops that wait on the server (devicePoll, jamPoll): wake when an event says there's something, or
/// when the stream goes up or down (to switch between waiting here and long-polling).
class LiveWake {
  bool _pending = false;
  Completer<void>? _waiting;

  void wake() {
    _pending = true;
    final w = _waiting;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// Returns at the next [wake] (at once if one came since the last return), or after [max].
  Future<void> wait(Duration max) async {
    if (!_pending) {
      final w = _waiting = Completer<void>();
      final t = Timer(max, () {
        if (!w.isCompleted) w.complete();
      });
      await w.future;
      t.cancel();
    }
    _pending = false;
    _waiting = null;
  }
}
