import 'package:flutter/services.dart';

import '../core/platform.dart';
import 'desktop_audio.dart';

/// System sound controls: media volume, where the sound plays, the output switcher. Android's, or on the
/// desktop Encore's own volume and the sound server's devices (desktop_audio.dart).
class AudioDevice {
  static const _ch = MethodChannel('encore/audio');

  static Future<(int, int)> volume() async {
    if (isDesktop) return ((desktopVolume * 100).round(), 100);
    final r = (await _ch.invokeMapMethod<String, dynamic>('volume')) ?? const {};
    return ((r['current'] as int?) ?? 0, (r['max'] as int?) ?? 15);
  }

  static Future<void> setVolume(int v) =>
      isDesktop ? setDesktopVolume(v / 100) : _ch.invokeMethod('setVolume', {'value': v});

  /// (name, kind): kind is speaker / bluetooth / headphones / tv / other.
  static Future<(String, String)> output() async {
    if (isDesktop) return desktopOutput();
    try {
      final r = (await _ch.invokeMapMethod<String, dynamic>('output')) ?? const {};
      return ((r['name'] ?? 'This phone').toString(), (r['type'] ?? 'speaker').toString());
    } catch (_) {
      return ('This phone', 'speaker');
    }
  }

  /// Android's output picker (on the desktop the sound panel lists the devices itself).
  static Future<void> showOutputSwitcher() async {
    if (!isDesktop) await _ch.invokeMethod('showOutputSwitcher');
  }

  /// 'sound', 'bluetooth', or 'accessibility' (mono audio and left/right balance live there on Android;
  /// on the desktop: KDE's sound or Bluetooth settings).
  static Future<void> openSettings(String which) =>
      isDesktop ? openKdeSettings(which) : _ch.invokeMethod('openSettings', {'which': which});
}
