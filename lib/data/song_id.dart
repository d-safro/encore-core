import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';

import '../core/platform.dart';
import '../core/settings.dart' show prefs;
import 'models.dart';
import 'subsonic.dart';

/// "What's playing?": Encore records a few seconds (the phone's microphone; on a Linux computer, what the
/// computer itself is playing) and your server recognises it among your own songs (music-lookup's
/// identifySong and the song-id container). Nothing goes anywhere else, so only songs you have are found.

const recordSeconds = 10;
const _system = MethodChannel('encore/system');

/// Whether this device can record for it (Android: the microphone; Linux: PipeWire / PulseAudio's monitor).
bool get canIdentify => !isDesktop || Platform.isLinux;

/// What the server said.
class Identification {
  const Identification({this.song, this.offset = 0, this.indexing = false, this.songs = 0, this.error});
  final Song? song;
  final double offset; // where in the song the recording was (s)
  final bool indexing; // still fingerprinting the library: try again later
  final int songs; // songs fingerprinted so far
  final String? error;

  bool get found => song != null;

  factory Identification.fromJson(Map<String, dynamic> j) => Identification(
    song: j['found'] == true && j['song'] is Map ? Song.fromJson((j['song'] as Map).cast<String, dynamic>()) : null,
    offset: (j['offset'] as num?)?.toDouble() ?? 0,
    indexing: j['indexing'] == true,
    songs: (j['songs'] as num?)?.toInt() ?? 0,
    error: j['error'] as String?,
  );
}

/// Record [recordSeconds] s; null when the microphone isn't allowed, or when [cancelled] says so (the sheet
/// was closed: recording stops then and nothing is sent). [onTick] gets the seconds left.
Future<List<int>?> recordClip({void Function(int left)? onTick, bool Function()? cancelled}) async {
  final dir = await getTemporaryDirectory();
  final ext = isDesktop ? 'wav' : 'm4a';
  final f = File('${dir.path}/encore-whats-playing.$ext');
  if (await f.exists()) await f.delete();
  Process? rec;
  if (isDesktop) {
    // what this computer is playing: PipeWire records the default output (PulseAudio's monitor without it)
    try {
      rec = await Process.start('pw-record', ['-P', '{ stream.capture.sink=true }', '--channels=1', '--rate=16000', f.path]);
    } on ProcessException {
      rec = await Process.start('parecord', ['--device=@DEFAULT_MONITOR@', '--channels=1', '--rate=16000', f.path]);
    }
  } else {
    if (await _system.invokeMethod<bool>('micPermission') != true) return null;
    await _system.invokeMethod('recordStart', {'path': f.path});
  }
  try {
    for (var left = recordSeconds; left > 0; left--) {
      if (cancelled?.call() ?? false) break;
      onTick?.call(left);
      await Future.delayed(const Duration(seconds: 1));
    }
  } finally {
    if (rec != null) {
      rec.kill(ProcessSignal.sigint);
      await rec.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => 0);
    } else {
      await _system.invokeMethod('recordStop');
    }
  }
  if (cancelled?.call() ?? false) {
    if (await f.exists()) await f.delete();
    return null;
  }
  final bytes = await f.readAsBytes();
  await f.delete();
  return bytes;
}

// ── What you identified (on this device) ──
const _key = 'identifiedSongs';

List<(Song, DateTime)> identifiedSongs() {
  try {
    return [
      for (final e in jsonDecode(prefs.getString(_key) ?? '[]') as List)
        if (e is Map && e['song'] is Map)
          (Song.fromJson((e['song'] as Map).cast<String, dynamic>()), DateTime.fromMillisecondsSinceEpoch(e['at'] as int)),
    ];
  } catch (_) {
    return const [];
  }
}

Future<void> rememberIdentified(Map<String, dynamic> songJson) async {
  final list = (jsonDecode(prefs.getString(_key) ?? '[]') as List).whereType<Map>().toList()
    ..removeWhere((e) => (e['song'] as Map?)?['id'] == songJson['id'])
    ..insert(0, {'song': songJson, 'at': DateTime.now().millisecondsSinceEpoch});
  await prefs.setString(_key, jsonEncode(list.take(50).toList()));
}

/// Record, send, and remember a find.
Future<Identification?> whatsPlaying(SubsonicClient c, {void Function(int left)? onTick, bool Function()? cancelled}) async {
  final clip = await recordClip(onTick: onTick, cancelled: cancelled);
  if (clip == null) return null;
  final raw = await c.identifySong(clip);
  final r = Identification.fromJson(raw);
  if (r.found && raw['song'] is Map) await rememberIdentified((raw['song'] as Map).cast<String, dynamic>());
  return r;
}
