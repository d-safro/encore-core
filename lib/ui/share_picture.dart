import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/platform.dart';
import 'actions.dart' show toast;

/// Turn what's drawn inside the RepaintBoundary with [key] into a 1080-px-wide PNG and share it (phone), or
/// save it to Downloads (the desktop can't share files). Used by the year in review and lyric cards.
Future<void> sharePicture(BuildContext context, GlobalKey key, String name, {String text = ''}) async {
  try {
    final box = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (box == null) return;
    final img = await box.toImage(pixelRatio: 1080 / box.size.width);
    final png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final file = '${name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').toLowerCase()}.png';
    if (isDesktop) {
      final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
      final f = File('${dir.path}/$file');
      await f.writeAsBytes(png);
      if (context.mounted) toast(context, 'Saved to ${f.path}');
    } else {
      final f = File('${(await getTemporaryDirectory()).path}/$file');
      await f.writeAsBytes(png);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'image/png')], text: text));
    }
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t make the picture: $e');
  }
}
