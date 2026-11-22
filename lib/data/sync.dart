import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'account.dart';
import 'devices.dart';
import 'follows.dart';
import 'library_pins.dart';
import 'shows.dart';
import 'subsonic.dart';

/// Small things kept the same on all your devices (through the server's extras, music-lookup): pinned
/// playlists and albums, the Home sections, smart-shuffle songs you dropped, lyrics you picked, podcast
/// episodes marked played. The newest change wins. Without the extras each device keeps its own.

/// What is synced: the key on the server, how to read it here, and how to put a value from elsewhere back.
class SyncedValue {
  const SyncedValue(this.key, this.read, this.write);
  final String key;
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

SyncedValue _pref(String k, {void Function(Ref ref)? after}) => SyncedValue(
  k,
  (_) => _prefJson(k),
  (ref, v) {
    prefs.setString(k, jsonEncode(v));
    after?.call(ref);
  },
);

final syncedValues = <SyncedValue>[
  _pref('libraryPins', after: (ref) => ref.invalidate(libraryPinsProvider)),
  _pref('smartShuffleHidden'),
  _pref('lyricsPicks'),
  _pref('podcastDone'),
  _pref('followedArtists', after: (ref) => ref.invalidate(followsProvider)),
  _pref('showsPrefs', after: (ref) => ref.invalidate(showsPrefsProvider)),
  _pref('notForMe'), // songs and artists not to suggest (playback/not_for_me.dart)
  _pref('playlistTransitions'), // Edit transitions (playback/transitions.dart)
  SyncedValue(
    'homeSections',
    (ref) => ref.read(settingsProvider).homeSections,
    (ref, v) {
      if (v is List) ref.read(settingsProvider.notifier).update({'homeSections': v.map((e) => '$e').toList()});
    },
  ),
];

/// The value as last agreed with the server, to tell a change made here from one made elsewhere.
String _lastKey(String k) => 'syncLast:$k';
String _atKey(String k) => 'syncAt:$k';

/// Decides, for one value, what to do: send ours, take theirs, or nothing. Texts are JSON (null: none).
/// [last] is what both agreed on last time, [lastAt] when the server's copy of that was made, [serverAt] when
/// the server's current value was made.
enum SyncStep { send, take, none }

SyncStep syncStep({
  required String? local,
  required String? last,
  required int lastAt,
  required String? server,
  required int serverAt,
}) {
  if (server == null) return local != null ? SyncStep.send : SyncStep.none;
  if (server == local) return SyncStep.none;
  if (last == null) return SyncStep.take; // the first time on this device: what your other devices have wins
  final changedHere = local != last;
  final changedThere = serverAt > lastAt;
  if (changedHere) return SyncStep.send; // noticed within half a minute: newer than the server's
  return changedThere ? SyncStep.take : SyncStep.none;
}

class SyncNotifierService extends Notifier<DateTime?> {
  Timer? _timer;
  bool _busy = false;

  @override
  DateTime? build() {
    final c = ref.watch(clientProvider);
    final supported = ref.watch(devicesProvider.select((d) => d.supported));
    _timer?.cancel();
    ref.onDispose(() => _timer?.cancel());
    if (c != null && supported == true) {
      Future.microtask(() => syncNow());
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => syncNow());
    }
    return null;
  }

  Future<void> syncNow() async {
    final c = ref.read(clientProvider);
    if (c == null || _busy) return;
    _busy = true;
    try {
      final r = await c.call('syncGet');
      final values = ((r['sync'] as Map?)?['values'] as Map?)?.cast<String, dynamic>() ?? const {};
      for (final v in syncedValues) {
        final srv = (values[v.key] as Map?)?.cast<String, dynamic>();
        final local = v.read(ref);
        final localText = local == null ? null : jsonEncode(local);
        final serverText = srv == null ? null : jsonEncode(srv['value']);
        final serverAt = (srv?['at'] as num?)?.toInt() ?? 0;
        switch (syncStep(
          local: localText,
          last: prefs.getString(_lastKey(v.key)),
          lastAt: prefs.getInt(_atKey(v.key)) ?? 0,
          server: serverText,
          serverAt: serverAt,
        )) {
          case SyncStep.send:
            final at = DateTime.now().millisecondsSinceEpoch;
            final r = await c.call('syncSet', {'key': v.key, 'value': localText, 'at': at, 'id': deviceId()});
            final kept = ((r['sync'] as Map?)?['value'] as Map?)?['at'];
            await prefs.setString(_lastKey(v.key), localText!);
            await prefs.setInt(_atKey(v.key), (kept as num?)?.toInt() ?? at);
          case SyncStep.take:
            v.write(ref, srv!['value']);
            await prefs.setString(_lastKey(v.key), serverText!);
            await prefs.setInt(_atKey(v.key), serverAt);
          case SyncStep.none:
            if (localText != null && localText == serverText) {
              await prefs.setString(_lastKey(v.key), localText);
              await prefs.setInt(_atKey(v.key), serverAt);
            }
        }
      }
      state = DateTime.now();
    } on SubsonicException catch (_) {
      // no extras on this server
    } catch (_) {
      // offline: next time
    } finally {
      _busy = false;
    }
  }
}

final syncServiceProvider = NotifierProvider<SyncNotifierService, DateTime?>(SyncNotifierService.new);
