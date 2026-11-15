import 'package:flutter/services.dart';

/// System sound controls (Android): media volume, where the sound plays, the output switcher.
class AudioDevice {
  static const _ch = MethodChannel('encore/audio');

  static Future<(int, int)> volume() async {
    final r = (await _ch.invokeMapMethod<String, dynamic>('volume')) ?? const {};
    return ((r['current'] as int?) ?? 0, (r['max'] as int?) ?? 15);
  }

  static Future<void> setVolume(int v) => _ch.invokeMethod('setVolume', {'value': v});

  /// (name, kind): kind is speaker / bluetooth / headphones / tv / other.
  static Future<(String, String)> output() async {
    try {
      final r = (await _ch.invokeMapMethod<String, dynamic>('output')) ?? const {};
      return ((r['name'] ?? 'This phone').toString(), (r['type'] ?? 'speaker').toString());
    } catch (_) {
      return ('This phone', 'speaker');
    }
  }

  static Future<void> showOutputSwitcher() => _ch.invokeMethod('showOutputSwitcher');

  /// 'sound', 'bluetooth', or 'accessibility' (mono audio and left/right balance live there on Android).
  static Future<void> openSettings(String which) => _ch.invokeMethod('openSettings', {'which': which});
}
