import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'account.dart';
import 'devices.dart';
import 'events.dart';
import 'follows.dart';
import 'library_pins.dart';
import 'shows.dart';
import 'subsonic.dart';

/// Small things kept the same on all your devices (through the server's extras, music-lookup): pinned
/// playlists and albums, the Home sections, smart-shuffle songs you dropped, lyrics you picked, podcast
/// episodes marked played. The newest change wins; for lists of things (episodes played, artists followed...)
/// changes made on two devices at once are put together. Without the extras each device keeps its own.

/// What is synced: the key on the server, how to read it here, and how to put a value from elsewhere back.
class SyncedValue {
  const SyncedValue(this.key, this.read, this.write, {this.merge = false});
  final String key;
  final bool merge; // a set of things: changes from both sides are put together (mergeSynced)
  final Object? Function(Ref ref) read;
  final void Function(Ref ref, Object? value) write;
}

Object? _prefJson(String k) {
  final raw = prefs.getString(k);
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

SyncedValue _pref(String k, {void Function(Ref ref)? after, bool merge = false}) => SyncedValue(
  k,
  (_) => _prefJson(k),
  (ref, v) {
    prefs.setString(k, jsonEncode(v));
    after?.call(ref);
  },
  merge: merge,
);

final syncedValues = <SyncedValue>[
  _pref('libraryPins', after: (ref) => ref.invalidate(libraryPinsProvider)),
  _pref('smartShuffleHidden'),
  _pref('lyricsPicks', merge: true),
  _pref('podcastDone', merge: true),
  _pref('followedArtists', after: (ref) => ref.invalidate(followsProvider), merge: true),
  _pref('showsPrefs', after: (ref) => ref.invalidate(showsPrefsProvider)),
  _pref('notForMe', merge: true), // songs and artists not to suggest (playback/not_for_me.dart)
  _pref('playlistTransitions'), // Edit transitions (playback/transitions.dart)
  SyncedValue(
    'homeSections',
    (ref) => ref.read(settingsProvider).homeSections,
    (ref, v) {
      if (v is List) ref.read(settingsProvider.notifier).update({'homeSections': v.map((e) => '$e').toList()});
    },
  ),
  // the skip buttons' seconds and which songs get them (Settings › Playback)
  SyncedValue(
    'playerSkip',
    (ref) => ref.read(settingsProvider).skipSynced,
    (ref, v) => ref.read(settingsProvider.notifier).update(Settings.skipFromSynced(v)),
  ),
];

/// The value as last agreed with the server, to tell a change made here from one made elsewhere.
String _lastKey(String k) => 'syncLast:$k';
String _atKey(String k) => 'syncAt:$k';

/// A change made here, and when it was first noticed (the sync looks every half minute): its time.
String _seenKey(String k) => 'syncSeen:$k';
String _seenAtKey(String k) => 'syncSeenAt:$k';

/// Decides, for one value, what to do: send ours, take theirs, put both together, or nothing. Texts are JSON
/// (null: none). [last] is what both agreed on last time, [lastAt] when the server's copy of that was made,
/// [serverAt] when the server's current value was made, [localAt] when the change here was made.
enum SyncStep { send, take, merge, none }

SyncStep syncStep({
  required String? local,
  required String? last,
  required int lastAt,
  required String? server,
  required int serverAt,
  int localAt = 0,
  bool mergeable = false,
}) {
  if (server == null) return local != null ? SyncStep.send : SyncStep.none;
  if (server == local) return SyncStep.none;
  // the first time on this device: what your other devices have wins (a set of things: both kept)
  if (last == null) return mergeable && local != null ? SyncStep.merge : SyncStep.take;
  final changedHere = local != last;
  final changedThere = serverAt > lastAt;
  if (changedHere && changedThere) {
    // changed on both: both kept for a set of things, else the newer one wins
    if (mergeable && local != null) return SyncStep.merge;
    return serverAt > localAt ? SyncStep.take : SyncStep.send;
  }
  if (changedHere) return SyncStep.send;
  return changedThere ? SyncStep.take : SyncStep.none;
}

/// Puts together changes made here ([local]) and elsewhere ([server]) to what both had ([base]): what was
/// added on either side stays, what was removed on either side goes. Maps go key by key; lists are taken as
/// sets (of plain values, or of maps by their 'id'). When both changed the same thing, [preferLocal] says
/// whose wins.
Object? mergeSynced(Object? base, Object? local, Object? server, {bool preferLocal = true}) {
  final enc = jsonEncode;
  if (enc(local) == enc(server)) return local;
  if (enc(local) == enc(base)) return server;
  if (enc(server) == enc(base)) return local;
  if (local is Map && server is Map) {
    final b = base is Map ? base : const {};
    final out = <String, Object?>{};
    for (final k in {...server.keys, ...local.keys}.map((k) => '$k')) {
      final inL = local.containsKey(k), inS = server.containsKey(k), inB = b.containsKey(k);
      if (!inL && !inS) continue;
      if (!inL) {
        if (!inB || enc(b[k]) != enc(server[k])) out[k] = server[k]; // removed here, unless changed there
        continue;
      }
      if (!inS) {
        if (!inB || enc(b[k]) != enc(local[k])) out[k] = local[k]; // removed there, unless changed here
        continue;
      }
      out[k] = mergeSynced(b[k], local[k], server[k], preferLocal: preferLocal);
    }
    return out;
  }
  if (local is List && server is List) {
    String id(Object? e) => e is Map && e['id'] != null ? 'id:${e['id']}' : enc(e);
    final b = {for (final e in base is List ? base : const []) id(e)};
    final mine = {for (final e in local) id(e): e};
    final theirs = {for (final e in server) id(e)};
    return [
      for (final e in server)
        if (mine.containsKey(id(e)) || !b.contains(id(e))) preferLocal ? mine[id(e)] ?? e : e,
      for (final e in local)
        if (!theirs.contains(id(e)) && !b.contains(id(e))) e,
    ];
  }
  return preferLocal ? local : server;
}

/// With Conductor's live updates up, the server is asked only when something changed: here (seen at the
/// half-minute look, which then stays on this device), elsewhere (an event says so), or this long since the last
/// time anyway. Without them it's asked every half minute, as before.
const syncSafetyNet = Duration(minutes: 10);

bool syncShouldAsk({required bool live, required bool changedHere, required DateTime? lastAsked, DateTime? now}) {
  if (!live || changedHere || lastAsked == null) return true;
  return (now ?? DateTime.now()).difference(lastAsked) >= syncSafetyNet;
}

class SyncNotifierService extends Notifier<DateTime?> {
  Timer? _timer;
  StreamSubscription? _events;
  bool _busy = false, _again = false;
  DateTime? _askedAt;

  @override
  DateTime? build() {
    final c = ref.watch(clientProvider);
    final supported = ref.watch(devicesProvider.select((d) => d.supported));
    final live = ref.watch(liveEventsProvider);
    _timer?.cancel();
    _events?.cancel();
    ref.onDispose(() {
      _timer?.cancel();
      _events?.cancel();
    });
    if (c != null && supported == true) {
      Future.microtask(() => syncNow());
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => _look());
      // changed on another device (not this one's own change coming back), or a gap in the stream: ask now
      _events = live?.events
          .where((e) => (e.type == 'sync' && e.data['by'] != deviceId()) || e.type == 'resync')
          .listen((_) => syncNow());
    }
    return null;
  }

  void _look() {
    final live = ref.read(liveEventsProvider)?.healthy == true;
    if (live) _noteLocalChanges();
    if (syncShouldAsk(live: live, changedHere: _changedHere(), lastAsked: _askedAt)) syncNow();
  }

  /// Something here isn't what was last agreed with the server.
  bool _changedHere() => syncedValues.any((v) {
    final local = v.read(ref);
    return (prefs.getString(_lastKey(v.key)) ?? '') != (local == null ? '' : jsonEncode(local));
  });

  /// When each value last changed here: noticed at each look (every half minute, offline too), so a change
  /// made offline isn't taken for newer than one made elsewhere meanwhile.
  void _noteLocalChanges() {
    for (final v in syncedValues) {
      final local = v.read(ref);
      final text = local == null ? '' : jsonEncode(local);
      final last = prefs.getString(_lastKey(v.key));
      if ((last ?? '') == text) continue; // as agreed with the server: nothing new here
      if (prefs.getString(_seenKey(v.key)) == text) continue; // noticed already
      prefs.setString(_seenKey(v.key), text);
      prefs.setInt(_seenAtKey(v.key), DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// [text] is what this device and the server agree on now (as of the server's [at]).
  Future<void> _agreed(String key, String text, int at) async {
    await prefs.setString(_lastKey(key), text);
    await prefs.setInt(_atKey(key), at);
    await prefs.remove(_seenKey(key));
    await prefs.remove(_seenAtKey(key));
  }

  Future<void> syncNow() async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    if (_busy) {
      _again = true; // asked again meanwhile (an event): once more when this one's done
      return;
    }
    _busy = true;
    try {
      _noteLocalChanges();
      final r = await c.call('syncGet');
      final values = ((r['sync'] as Map?)?['values'] as Map?)?.cast<String, dynamic>() ?? const {};
      for (final v in syncedValues) {
        final srv = (values[v.key] as Map?)?.cast<String, dynamic>();
        final local = v.read(ref);
        final localText = local == null ? null : jsonEncode(local);
        final serverText = srv == null ? null : jsonEncode(srv['value']);
        final serverAt = (srv?['at'] as num?)?.toInt() ?? 0;
        final last = prefs.getString(_lastKey(v.key));
        final localAt = prefs.getInt(_seenAtKey(v.key)) ?? 0; // when the change here was made (0: none)
        Future<void> send(String text) async {
          final at = DateTime.now().millisecondsSinceEpoch;
          final r = await c.call('syncSet', {'key': v.key, 'value': text, 'at': at, 'id': deviceId()});
          final kept = ((r['sync'] as Map?)?['value'] as Map?)?['at'];
          await _agreed(v.key, text, (kept as num?)?.toInt() ?? at);
        }
        switch (syncStep(
          local: localText,
          last: last,
          lastAt: prefs.getInt(_atKey(v.key)) ?? 0,
          server: serverText,
          serverAt: serverAt,
          localAt: localAt,
          mergeable: v.merge,
        )) {
          case SyncStep.send:
            await send(localText!);
          case SyncStep.merge:
            final base = last == null ? null : jsonDecode(last);
            final both = mergeSynced(base, local, srv!['value'], preferLocal: localAt >= serverAt);
            final text = jsonEncode(both);
            if (text != localText) v.write(ref, both);
            if (text == serverText) {
              await _agreed(v.key, text, serverAt);
            } else {
              await send(text);
            }
          case SyncStep.take:
            v.write(ref, srv!['value']);
            await _agreed(v.key, serverText!, serverAt);
          case SyncStep.none:
            if (localText != null && localText == serverText) await _agreed(v.key, localText, serverAt);
        }
      }
      state = _askedAt = DateTime.now();
    } on SubsonicException catch (_) {
      // no extras on this server
    } catch (_) {
      // offline: next time
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        unawaited(syncNow());
      }
    }
  }
}

final syncServiceProvider = NotifierProvider<SyncNotifierService, DateTime?>(SyncNotifierService.new);
