import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:home_widget/home_widget.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Keeps the home-screen widget showing what's playing (song, artist, cover, play/pause state).
void startWidgetSync(AudioHandler handler) {
  String? lastId;
  bool? lastPlaying;

  Future<void> push() async {
    try {
      await HomeWidget.updateWidget(qualifiedAndroidName: 'dev.safro.encore.EncoreWidget');
    } catch (_) {}
  }

  handler.mediaItem.listen((item) async {
    if (item == null || item.id == lastId) return;
    lastId = item.id;
    try {
      await HomeWidget.saveWidgetData<String>('title', item.title);
      await HomeWidget.saveWidgetData<String>('artist', item.artist ?? '');
    } catch (_) {}
    String? coverPath;
    final art = item.artUri;
    if (art != null) {
      try {
        // the picture kept on the phone (works with no server), else the server's
        List<int>? bytes;
        if (art.scheme == 'file') {
          bytes = await File(art.toFilePath()).readAsBytes();
        } else {
          final res = await http.get(art).timeout(const Duration(seconds: 10));
          if (res.statusCode == 200) bytes = res.bodyBytes;
        }
        // skipped on meanwhile (a slow server cover): the newer song's cover is already there
        if (lastId != item.id) return;
        if (bytes != null) {
          final dir = await getApplicationSupportDirectory();
          final f = File(p.join(dir.path, 'widget_cover.jpg'));
          await f.writeAsBytes(bytes, flush: true);
          coverPath = f.path;
        }
      } catch (_) {}
    }
    if (lastId != item.id) return;
    try {
      await HomeWidget.saveWidgetData<String>('cover', coverPath, deleteFile: false);
    } catch (_) {}
    await push();
  });

  handler.playbackState.listen((s) async {
    if (s.playing == lastPlaying) return;
    lastPlaying = s.playing;
    try {
      await HomeWidget.saveWidgetData<bool>('playing', s.playing);
    } catch (_) {}
    await push();
  });
}
