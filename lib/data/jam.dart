import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../playback/handler.dart';
import 'account.dart';
import 'library.dart';
import 'models.dart';
import 'subsonic.dart';

/// Jam (like Spotify Jam): friends open a link, search your library and change what's playing.
/// Your server (music-lookup) hosts the guest page; this keeps it up to date with the queue and applies what
/// guests do: add (after earlier guest adds, in order), reorder, remove, skip.
class JamState {
  const JamState({this.active = false, this.busy = false, this.url, this.guests = 0, this.error});
  final bool active, busy;
  final String? url, error;
  final int guests;
}

class JamNotifier extends Notifier<JamState> {
  String? _token;
  int _ack = 0;
  int _run = 0; // bumps when a Jam starts or ends, so old loops stop
  Timer? _pushTimer, _heartbeat;
  final _subs = <StreamSubscription>[];
  final addedBy = <String, String>{}; // song id -> guest name
  final _guestAdds = <String>[]; // songs guests added, in order (they play after each other)

  @override
  JamState build() {
    ref.onDispose(_stopLoops);
    final token = prefs.getString('jamToken'), url = prefs.getString('jamUrl');
    if (token != null && url != null) {
      // the app was closed during a Jam: pick it up again
      Future.microtask(() => _begin(token, url));
      return JamState(active: true, url: url);
    }
    return const JamState();
  }

  SubsonicClient? get _client => ref.read(clientProvider);

  Future<void> start() async {
    final c = _client;
    if (c == null || state.active) return;
    state = const JamState(busy: true);
    try {
      final r = await c.call('jamStart', {'name': _hostName()});
      final j = (r['jam'] as Map).cast<String, dynamic>();
      _begin('${j['token']}', '${j['url']}');
    } on SubsonicException catch (e) {
      state = JamState(error: e.message);
    } catch (e) {
      state = JamState(error: "Couldn't start the Jam: $e");
    }
  }

  Future<void> end() async {
    final c = _client, token = _token;
    _finish();
    if (c != null && token != null) {
      try {
        await c.call('jamEnd', {'token': token});
      } catch (_) {}
    }
  }

  String _hostName() {
    final u = ref.read(accountProvider).value?.username ?? '';
    return u.isEmpty ? 'Encore' : '${u[0].toUpperCase()}${u.substring(1)}';
  }

  void _begin(String token, String url) {
    _token = token;
    _ack = 0;
    prefs.setString('jamToken', token);
    prefs.setString('jamUrl', url);
    state = JamState(active: true, url: url);
    final run = ++_run;
    _stopLoops();
    _subs
      ..add(audioHandler.queue.listen((_) => _pushSoon()))
      ..add(audioHandler.mediaItem.listen((_) => _pushSoon()))
      ..add(audioHandler.playbackState.map((s) => s.playing).distinct().listen((_) => _pushSoon()));
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) => _pushSoon());
    _pushSoon();
    _poll(run);
  }

  void _finish() {
    _run++;
    _stopLoops();
    _token = null;
    addedBy.clear();
    _guestAdds.clear();
    prefs.remove('jamToken');
    prefs.remove('jamUrl');
    state = const JamState();
  }

  void _stopLoops() {
    _pushTimer?.cancel();
    _heartbeat?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  // ── Sending the queue to the guest page ──
  void _pushSoon() {
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(milliseconds: 400), _push);
  }

  Map<String, dynamic> _item(Song s, [int? i]) => {
    'i': ?i,
    'id': s.id,
    'title': s.title,
    'artist': s.artist,
    'album': s.album,
    'cover': s.coverArt,
    'duration': s.duration ?? 0,
    'by': addedBy[s.id] ?? '',
  };

  Future<void> _push() async {
    final c = _client, token = _token;
    if (c == null || token == null || ref.read(offlineProvider)) return;
    final songs = audioHandler.songs;
    final st = audioHandler.playbackState.value;
    final cur = audioHandler.player.currentIndex ?? 0;
    final now = audioHandler.radioStation == null ? audioHandler.currentSong : null;
    final state_ = {
      'sentAt': DateTime.now().millisecondsSinceEpoch,
      'now': now == null ? null : _item(now),
      'radio': audioHandler.radioStation?.name,
      'positionMs': audioHandler.player.position.inMilliseconds,
      'playing': st.playing,
      'index': cur,
      'total': songs.length,
      'queue': [for (var i = cur + 1; i < songs.length && i <= cur + 60; i++) _item(songs[i], i)],
    };
    try {
      await c.call('jamState', {'token': token, 'state': jsonEncode(state_)});
    } on SubsonicException catch (e) {
      if (e.code == 70) _finish(); // ended (or the server forgot it)
    } catch (_) {}
  }

  // ── Guest actions ──
  Future<void> _poll(int run) async {
    var failures = 0;
    while (run == _run && _token != null) {
      final c = _client;
      if (c == null || ref.read(offlineProvider)) {
        await Future.delayed(const Duration(seconds: 5));
        continue;
      }
      try {
        final r = await c.call(
          'jamPoll',
          {'token': _token, 'ack': '$_ack', 'wait': '20'},
          null,
          const Duration(seconds: 35),
        );
        if (run != _run) return;
        final j = (r['jam'] as Map).cast<String, dynamic>();
        final guests = (j['guests'] as num?)?.toInt() ?? 0;
        if (guests != state.guests) state = JamState(active: true, url: state.url, guests: guests);
        for (final cmd in (j['commands'] as List? ?? const [])) {
          if (cmd is! Map) continue;
          _ack = max(_ack, (cmd['seq'] as num?)?.toInt() ?? _ack);
          try {
            await _apply(cmd.cast<String, dynamic>());
          } catch (_) {}
        }
        failures = 0;
      } on SubsonicException catch (e) {
        if (e.code == 70) return _finish();
        failures++;
      } catch (_) {
        failures++;
      }
      if (failures > 0) await Future.delayed(Duration(seconds: min(30, 2 * failures)));
    }
  }

  int _find(String id, int hint) {
    final songs = audioHandler.songs;
    if (hint >= 0 && hint < songs.length && songs[hint].id == id) return hint;
    // the queue moved since the guest looked: the nearest copy of that song after the playing one
    final cur = audioHandler.player.currentIndex ?? 0;
    for (var i = cur; i < songs.length; i++) {
      if (songs[i].id == id) return i;
    }
    return songs.indexWhere((s) => s.id == id);
  }

  Future<void> _apply(Map<String, dynamic> cmd) async {
    final id = '${cmd['id'] ?? ''}';
    final by = '${cmd['by'] ?? ''}';
    final cur = audioHandler.player.currentIndex ?? 0;
    switch (cmd['type']) {
      case 'add':
        final songs = await ref.read(repoProvider).resolveSongs([id]);
        if (songs.isEmpty) return;
        if (by.isNotEmpty) addedBy[id] = by;
        // after the playing song and after songs guests added before (still to come), like Spotify Jam
        final q = audioHandler.songs;
        var at = cur + 1;
        for (var i = cur + 1; i < q.length; i++) {
          if (_guestAdds.contains(q[i].id)) at = i + 1;
        }
        _guestAdds.add(id);
        if (_guestAdds.length > 500) _guestAdds.removeAt(0);
        await audioHandler.insertSongs(at, songs);
        if (!audioHandler.player.playing && audioHandler.songs.length == 1) await audioHandler.play();
      case 'move':
        final from = _find(id, (cmd['from'] as num?)?.toInt() ?? -1);
        final to = ((cmd['to'] as num?)?.toInt() ?? from)
            .clamp(cur + 1, max(cur + 1, audioHandler.songs.length - 1))
            .toInt();
        if (from > cur && from != to) await audioHandler.moveQueueItem(from, to);
      case 'remove':
        final i = _find(id, (cmd['from'] as num?)?.toInt() ?? (cmd['index'] as num?)?.toInt() ?? -1);
        if (i < 0) return;
        if (i == cur) {
          if (audioHandler.player.hasNext) await audioHandler.skipToNext();
          await audioHandler.removeQueueItemAt(i);
        } else {
          await audioHandler.removeQueueItemAt(i);
        }
      case 'skip':
        if (id.isEmpty || audioHandler.currentSong?.id == id) await audioHandler.skipToNext();
    }
    _pushSoon();
  }
}

final jamProvider = NotifierProvider<JamNotifier, JamState>(JamNotifier.new);
