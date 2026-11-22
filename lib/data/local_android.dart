import 'dart:async';

import 'package:flutter/services.dart';

import 'local_files.dart';

/// Android: the phone's music from MediaStore (the system's index of audio files; tags read by Android),
/// with the "Music and audio" permission asked when you first open On this device. Encore's own downloads
/// are in its private folder, which MediaStore doesn't list, so they don't show twice.
/// The Kotlin side is MainActivity's encore/system channel.
class MediaStoreSource extends LocalSource {
  static const _ch = MethodChannel('encore/system');

  @override
  Future<bool> allowed({bool ask = false}) async {
    try {
      return await _ch.invokeMethod<bool>('audioPermission', {'ask': ask}) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<LocalTrack>> scan(Map<String, LocalTrack> known) async {
    final covers = await localCoversDir();
    await covers.create(recursive: true);
    final rows = await _ch.invokeListMethod<Map>('mediaStoreAudio', {'covers': covers.path}) ?? const [];
    return [for (final r in rows) ?trackFromMediaStore(r)];
  }
}

/// One MediaStore row (from MainActivity) as a track.
LocalTrack? trackFromMediaStore(Map r) {
  final uri = '${r['uri'] ?? ''}';
  if (uri.isEmpty) return null;
  int? n(Object? v) => v is num && v > 0 ? v.toInt() : null;
  final cover = '${r['cover'] ?? ''}';
  var track = n(r['track']);
  if (track != null && track >= 1000) track %= 1000; // MediaStore: disc * 1000 + track
  final title = '${r['title'] ?? ''}'.trim();
  final artist = '${r['artist'] ?? ''}'.trim();
  return LocalTrack(
    uri: uri,
    title: title.isEmpty ? titleFromFileName('${r['name'] ?? uri}') : title,
    artist: artist == '<unknown>' ? '' : artist,
    album: '${r['album'] ?? ''}'.trim(),
    track: track,
    year: n(r['year']),
    duration: n(r['duration']) == null ? null : (n(r['duration'])! / 1000).round(),
    cover: cover.isEmpty ? '' : 'file:$cover',
    mtime: n(r['mtime']) ?? 0,
  );
}

/// "Open with Encore" from another app: the file it was opened with (content:// or file://), read by Android.
Future<LocalTrack?> probeAndroidFile(String uri) async {
  try {
    final covers = await localCoversDir();
    final r = await const MethodChannel('encore/system').invokeMapMethod<String, Object?>(
      'probeAudio',
      {'uri': uri, 'covers': covers.path},
    );
    return r == null ? null : trackFromMediaStore({...r, 'uri': uri});
  } catch (_) {
    return null;
  }
}
