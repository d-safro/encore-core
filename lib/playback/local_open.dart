import 'dart:io';

import 'package:flutter/services.dart';

import '../core/platform.dart';
import '../data/local_android.dart';
import '../data/local_files.dart';
import 'handler.dart';

/// Playing files that were opened with Encore: "Open with Encore" on Android, `encore song.flac`, the file
/// manager or a file dropped on the window on the desktop. Their tags are read, they play at once (several:
/// in the order given), and they stay in the queue like any song.
Future<void> openFiles(List<String> uris) async {
  final songs = [
    for (final u in uris)
      if (await _track(u) case final t?) openedFile(t),
  ];
  if (songs.isNotEmpty) await audioHandler.playSongs(songs);
}

Future<LocalTrack?> _track(String uri) async {
  if (!isDesktop) return probeAndroidFile(uri);
  final path = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
  final f = File(path);
  if (!await f.exists() || !isAudioFile(path)) return null;
  return readTags(f, coversDir: await localCoversDir());
}

const _files = MethodChannel('encore/files');

/// Listen for files handed over while Encore runs (a second launch, Android's onNewIntent), and play the one
/// it was started with. [startedWith]: the desktop's command-line files.
Future<void> listenForOpenedFiles({List<String> startedWith = const []}) async {
  _files.setMethodCallHandler((call) async {
    if (call.method == 'open' && call.arguments is List) {
      await openFiles([for (final u in call.arguments as List) '$u']);
    }
    return null;
  });
  var first = startedWith;
  if (!isDesktop) {
    try {
      first = [for (final u in await _files.invokeListMethod<String>('initial') ?? const <String>[]) u];
    } catch (_) {}
  }
  if (first.isNotEmpty) await openFiles(first);
}

/// The audio files among command-line arguments (options like --hidden aren't files).
List<String> fileArgs(List<String> args) =>
    [for (final a in args) if (!a.startsWith('--') && isAudioFile(a.startsWith('file://') ? Uri.parse(a).path : a)) a];
