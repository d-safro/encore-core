import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/platform.dart';
import '../core/settings.dart';
import '../playback/audio_device.dart';
import '../playback/handler.dart';
import 'account.dart';
import 'library.dart';
import 'subsonic.dart';

/// Your devices running Encore (the phone, the desktop app) see each other through the server (music-lookup's
/// devices.py): each says hello, tells the others what it's playing, and waits for commands. So one can pause,
/// skip or turn down the other, and playback can move from one to the other ("Play here" / "Play on …").
/// Servers without the extras don't have this; then the list just stays empty.

/// This install's own id (the same for every server) and name.
String deviceId() {
  var id = prefs.getString('deviceId');
  if (id == null) {
    id = const Uuid().v4().replaceAll('-', '');
    prefs.setString('deviceId', id);
  }
  return id;
}

String _model = '';

/// What this device is called on your other devices: your own name for it, else the phone's model or the
/// computer's name.
String deviceName() {
  final own = prefs.getString('deviceName')?.trim() ?? '';
  if (own.isNotEmpty) return own;
  if (isDesktop) {
    final host = Platform.localHostname.split('.').first;
    return host.isEmpty ? 'Computer' : '${host[0].toUpperCase()}${host.substring(1)}';
  }
  return _model.isEmpty ? 'Phone' : _model;
}

Future<void> loadDeviceModel() async {
  if (isDesktop) return;
  try {
    _model = await const MethodChannel('encore/system').invokeMethod<String>('model') ?? '';
  } catch (_) {}
}

/// What a device is playing, as it last said.
class RemoteState {
  const RemoteState({
    this.songId = '',
    this.title = '',
    this.artist = '',
    this.album = '',
    this.coverArt = '',
    this.durationMs = 0,
    this.positionMs = 0,
    this.playing = false,
    this.volume = 1,
    this.queue = const [],
    this.index = 0,
    this.at = 0,
  });
  final String songId, title, artist, album, coverArt;
  final int durationMs, positionMs, index, at; // at: when it said this (server time, ms)
  final bool playing;
  final double volume; // 0..1
  final List<String> queue; // song ids

  bool get hasSong => songId.isNotEmpty;

  /// Where it is now: what it said, plus the time since while playing.
  int positionAt(int serverNow) {
    if (!playing || at == 0) return positionMs;
    final int p = positionMs + max(0, serverNow - at);
    return durationMs > 0 ? min(p, durationMs) : p;
  }

  Map<String, dynamic> toJson() => {
    'songId': songId,
    'title': title,
    'artist': artist,
    'album': album,
    'coverArt': coverArt,
    'duration': durationMs,
    'position': positionMs,
    'playing': playing,
    'volume': volume,
    'queue': queue,
    'index': index,
  };

  static RemoteState fromJson(Object? j) {
    if (j is! Map) return const RemoteState();
    int n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return RemoteState(
      songId: '${j['songId'] ?? ''}',
      title: '${j['title'] ?? ''}',
      artist: '${j['artist'] ?? ''}',
      album: '${j['album'] ?? ''}',
      coverArt: '${j['coverArt'] ?? ''}',
      durationMs: n(j['duration']),
      positionMs: n(j['position']),
      playing: j['playing'] == true,
      volume: (j['volume'] is num ? (j['volume'] as num).toDouble() : 1.0).clamp(0.0, 1.0),
      queue: [for (final x in (j['queue'] is List ? j['queue'] as List : const [])) '$x'],
      index: n(j['index']),
      at: n(j['at']),
    );
  }
}

class RemoteDevice {
  const RemoteDevice(this.id, this.name, this.kind, this.online, this.state);
  final String id, name, kind; // kind: phone, computer, tablet
  final bool online;
  final RemoteState state;

  static RemoteDevice? fromJson(Object? j) {
    if (j is! Map || j['id'] == null) return null;
    return RemoteDevice('${j['id']}', '${j['name'] ?? 'Encore'}', '${j['kind'] ?? 'phone'}', j['online'] == true,
        RemoteState.fromJson(j['state']));
  }
}

class DevicesState {
  const DevicesState({this.supported, this.devices = const [], this.serverNow = 0, this.clockSkew = 0});

  /// null: not known yet; false: the server doesn't have the extras.
  final bool? supported;

  /// Your other devices (not this one), online first.
  final List<RemoteDevice> devices;
  final int serverNow; // the server's clock at the last answer (ms)
  final int clockSkew; // server clock minus this device's clock (ms)

  List<RemoteDevice> get online => devices.where((d) => d.online).toList();
  int get now => DateTime.now().millisecondsSinceEpoch + clockSkew;
  RemoteDevice? byId(String id) => devices.where((d) => d.id == id).firstOrNull;
}

/// The commands a device understands (the others send them with [DevicesNotifier.send]).
abstract final class DeviceCommand {
  static const play = 'play', pause = 'pause', toggle = 'toggle', next = 'next', previous = 'previous';
  static const seek = 'seek'; // {position: ms}
  static const volume = 'volume'; // {volume: 0..1}
  static const playQueue = 'playQueue'; // {ids, index, position, play}: play these (playback moves here)
  static const skipTo = 'skipTo'; // {index}
}

class DevicesNotifier extends Notifier<DevicesState> {
  SubsonicClient? _client;
  int _run = 0; // bumps when the server changes, so an old loop stops
  int _ack = 0, _since = 0;
  Timer? _publishSoon, _watch;
  final _subs = <StreamSubscription>[];
  String _lastPublished = '';
  int _expectPos = 0;
  DateTime _expectAt = DateTime.now();

  @override
  DevicesState build() {
    final c = ref.watch(clientProvider);
    ref.onDispose(_stop);
    _client = c;
    if (c != null && (prefs.getBool('connectDevices') ?? true)) {
      final run = ++_run;
      Future.microtask(() => _loop(run));
    }
    return const DevicesState();
  }

  void _stop() {
    _run++;
    _publishSoon?.cancel();
    _watch?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  Map<String, dynamic> _me() => {'id': deviceId(), 'name': deviceName(), 'kind': deviceKind()};

  Future<void> _loop(int run) async {
    final c = _client;
    if (c == null) return;
    await loadDeviceModel();
    var wait = const Duration(seconds: 5);
    while (run == _run) {
      try {
        final r = await c.call('deviceHello', {..._me(), 'state': jsonEncode(await _myState())});
        _take(r['devices'], null);
        state = DevicesState(supported: true, devices: state.devices, serverNow: state.serverNow, clockSkew: state.clockSkew);
        _startPublishing();
        wait = const Duration(seconds: 5);
        while (run == _run) {
          final p = await c.call(
            'devicePoll',
            {'id': deviceId(), 'ack': _ack, 'since': _since, 'wait': 20},
            null,
            const Duration(seconds: 35),
          );
          if (run != _run) return;
          final poll = (p['devicePoll'] as Map?)?.cast<String, dynamic>() ?? const {};
          final now = (poll['now'] as num?)?.toInt() ?? 0;
          _take(poll['devices'], now);
          for (final cmd in (poll['commands'] as List? ?? const [])) {
            if (cmd is! Map) continue;
            _ack = max(_ack, (cmd['seq'] as num?)?.toInt() ?? 0);
            await _run1(cmd.cast<String, dynamic>());
          }
        }
      } on SubsonicException catch (e) {
        if (run != _run) return;
        // Navidrome alone: "unknown" call (or not found). Look again now and then (the extras may come later).
        final unknown = e.code == 0 || e.code == 70 || e.message.contains('404');
        if (unknown && state.supported != true) {
          state = const DevicesState(supported: false);
          wait = const Duration(minutes: 10);
        }
      } catch (_) {
        // offline or the server restarting: try again soon
      }
      if (run != _run) return;
      await Future.delayed(wait);
      if (wait < const Duration(minutes: 1)) wait *= 2;
    }
  }

  void _take(Object? raw, int? serverNow) {
    final list = raw is Map ? raw['device'] : raw;
    final all = [for (final j in (list is List ? list : const [])) ?RemoteDevice.fromJson(j)];
    final others = all.where((d) => d.id != deviceId()).toList();
    for (final d in others) {
      _since = max(_since, d.state.at);
    }
    final skew = serverNow != null ? serverNow - DateTime.now().millisecondsSinceEpoch : state.clockSkew;
    state = DevicesState(supported: true, devices: others, serverNow: serverNow ?? state.serverNow, clockSkew: skew);
  }

  // ── Telling the others what's playing here ──
  Future<Map<String, dynamic>> _myState() async {
    final h = audioHandler;
    final s = h.currentSong;
    final st = h.playbackState.value;
    double volume = 1;
    try {
      final (v, m) = await AudioDevice.volume();
      volume = m > 0 ? v / m : 1;
    } catch (_) {}
    final songs = h.songs;
    return RemoteState(
      songId: s?.id ?? '',
      title: s?.title ?? h.mediaItem.value?.title ?? '',
      artist: s?.artist ?? h.mediaItem.value?.artist ?? '',
      album: s?.album ?? '',
      coverArt: s?.coverArt ?? '',
      durationMs: (s?.duration ?? 0) * 1000,
      positionMs: h.player.position.inMilliseconds,
      playing: st.playing,
      volume: volume,
      queue: songs.length <= 500 ? [for (final x in songs) x.id] : const [],
      index: st.queueIndex ?? 0,
    ).toJson();
  }

  void _startPublishing() {
    if (_subs.isNotEmpty) return;
    final h = audioHandler;
    _subs.add(h.mediaItem.listen((_) => _soon()));
    _subs.add(h.playbackState.map((s) => (s.playing, s.queueIndex, s.processingState)).distinct().listen((_) => _soon()));
    _subs.add(h.queue.listen((_) => _soon()));
    // a seek: the position jumped from where it should be by now
    _watch = Timer.periodic(const Duration(seconds: 2), (_) {
      final p = h.player.position.inMilliseconds;
      final expected = _expectPos + (h.player.playing ? DateTime.now().difference(_expectAt).inMilliseconds : 0);
      if ((p - expected).abs() > 2500) _soon();
      _expectPos = p;
      _expectAt = DateTime.now();
    });
  }

  void _soon() {
    _publishSoon?.cancel();
    _publishSoon = Timer(const Duration(milliseconds: 600), publish);
  }

  /// Send what's playing here now (also after a volume change).
  Future<void> publish() async {
    final c = _client;
    if (c == null || state.supported != true) return;
    final me = await _myState();
    final text = jsonEncode(me);
    final key = jsonEncode({...me, 'position': 0});
    // the position alone moving on (playing normally) isn't news; anything else is
    if (key == _lastPublished && !_positionJumped(me)) return;
    _lastPublished = key;
    try {
      await c.call('deviceState', {'id': deviceId(), 'state': text});
    } catch (_) {}
  }

  int _publishedPos = 0;
  DateTime _publishedAt = DateTime.now();
  bool _positionJumped(Map<String, dynamic> me) {
    final p = (me['position'] as num?)?.toInt() ?? 0;
    final expected = _publishedPos + DateTime.now().difference(_publishedAt).inMilliseconds;
    _publishedPos = p;
    _publishedAt = DateTime.now();
    return (p - expected).abs() > 2500;
  }

  // ── Commands from the other devices ──
  Future<void> _run1(Map<String, dynamic> cmd) async {
    final h = audioHandler;
    int n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    try {
      switch (cmd['type']) {
        case DeviceCommand.play:
          await h.play();
        case DeviceCommand.pause:
          await h.pause();
        case DeviceCommand.toggle:
          h.playbackState.value.playing ? await h.pause() : await h.play();
        case DeviceCommand.next:
          await h.skipToNext();
        case DeviceCommand.previous:
          await h.skipToPrevious();
        case DeviceCommand.seek:
          await h.seek(Duration(milliseconds: n(cmd['position'])));
        case DeviceCommand.skipTo:
          await h.skipToQueueItem(n(cmd['index']));
        case DeviceCommand.volume:
          final v = ((cmd['volume'] as num?)?.toDouble() ?? 1).clamp(0.0, 1.0);
          final (_, m) = await AudioDevice.volume();
          await AudioDevice.setVolume((v * m).round());
          _soon();
        case DeviceCommand.playQueue:
          final ids = [for (final x in (cmd['ids'] as List? ?? const [])) '$x'];
          await playIds(ids, n(cmd['index']), n(cmd['position']), play: cmd['play'] != false);
      }
    } catch (_) {}
  }

  /// Play these songs here, from [index] at [positionMs].
  Future<bool> playIds(List<String> ids, int index, int positionMs, {bool play = true}) async {
    if (ids.isEmpty) return false;
    final songs = await ref.read(repoProvider).resolveSongs(ids);
    if (songs.isEmpty) return false;
    final want = index >= 0 && index < ids.length ? ids[index] : null;
    final at = max(0, songs.indexWhere((s) => s.id == want));
    await audioHandler.playSongs(songs, index: at);
    if (positionMs > 1000) await audioHandler.seek(Duration(milliseconds: positionMs));
    if (!play) await audioHandler.pause();
    return true;
  }

  // ── What you do from here ──

  /// Send a command to another device. False when the server didn't take it.
  Future<bool> send(String target, String type, [Map<String, dynamic> args = const {}]) async {
    final c = _client;
    if (c == null) return false;
    try {
      await c.call('deviceCommand', {'id': deviceId(), 'target': target, 'command': jsonEncode({'type': type, ...args})});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// "Play here": take over what [d] is playing, where it is, and pause it there.
  Future<bool> playHere(RemoteDevice d) async {
    final s = d.state;
    if (s.queue.isEmpty && s.songId.isEmpty) return false;
    final ids = s.queue.isNotEmpty ? s.queue : [s.songId];
    final index = s.queue.isNotEmpty ? s.index : 0;
    final ok = await playIds(ids, index, s.positionAt(state.now));
    if (ok) await send(d.id, DeviceCommand.pause);
    return ok;
  }

  /// "Play on …": hand what's playing here to [d] (it starts where this is) and pause here.
  Future<bool> playThere(RemoteDevice d) async {
    final h = audioHandler;
    final songs = h.songs;
    if (songs.isEmpty) return false;
    final ok = await send(d.id, DeviceCommand.playQueue, {
      'ids': [for (final s in songs.take(500)) s.id],
      'index': h.playbackState.value.queueIndex ?? 0,
      'position': h.player.position.inMilliseconds,
      'play': true,
    });
    if (ok) await h.pause();
    return ok;
  }

  /// Say goodbye (quitting), so the others drop this device at once.
  Future<void> bye() async {
    try {
      await _client?.call('deviceBye', {'id': deviceId()}, null, const Duration(seconds: 3));
    } catch (_) {}
  }
}

final devicesProvider = NotifierProvider<DevicesNotifier, DevicesState>(DevicesNotifier.new);

/// The icon for a kind of device.
String deviceKindLabel(String kind) => switch (kind) {
  'computer' => 'Computer',
  'tablet' => 'Tablet',
  _ => 'Phone',
};
