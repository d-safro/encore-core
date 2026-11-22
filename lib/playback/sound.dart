import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../core/host.dart';
import '../core/settings.dart';

/// The desktop's own sound (mpv's equalizer and skip-silence filters, extra loudness, Encore's own volume and
/// the sound server's output devices) lives in the desktop app; the shared player and screens reach it
/// through [DesktopSound] (see EncoreHost.sound) by the names below. On the phone, Android does all this and
/// none of it is called.
abstract class DesktopSound {
  const DesktopSound();

  /// Puts the remembered volume and device back when the app starts.
  Future<void> restore();

  /// Applies the sound settings (equalizer, skip silence) to every player.
  Future<void> apply(Settings s);

  /// Extra loudness (ReplayGain above the reference level), 0 for none.
  Future<void> setBoost(double db);

  /// Encore's own volume (0..1).
  double get volume;
  Future<void> setVolume(double v);
  Stream<double> get volumeChanges;

  /// The output devices to offer, the system default first.
  List<OutputDevice> devices();

  /// The chosen output device ('auto': the system default).
  String get device;
  Future<void> setDevice(String id);

  /// (name, kind) of where the sound plays now.
  (String, String) output();

  /// Opens the system's sound or Bluetooth settings ('sound' or 'bluetooth').
  Future<void> openSettings(String which);
}

class NoDesktopSound extends DesktopSound {
  const NoDesktopSound();
  @override
  Future<void> restore() async {}
  @override
  Future<void> apply(Settings s) async {}
  @override
  Future<void> setBoost(double db) async {}
  @override
  double get volume => 1.0;
  @override
  Future<void> setVolume(double v) async {}
  @override
  Stream<double> get volumeChanges => const Stream.empty();
  @override
  List<OutputDevice> devices() => const [OutputDevice('auto', 'This computer (system default)', 'speaker')];
  @override
  String get device => 'auto';
  @override
  Future<void> setDevice(String id) async {}
  @override
  (String, String) output() => ('This computer', 'speaker');
  @override
  Future<void> openSettings(String which) async {}
}

Future<void> restoreDesktopSound() => encoreHost.sound.restore();
Future<void> applyDesktopSound(Settings s) => encoreHost.sound.apply(s);
Future<void> setDesktopBoost(double db) => encoreHost.sound.setBoost(db);
double get desktopVolume => encoreHost.sound.volume;
Future<void> setDesktopVolume(double v) => encoreHost.sound.setVolume(v);
Stream<double> get desktopVolumeChanges => encoreHost.sound.volumeChanges;
List<OutputDevice> currentOutputDevices() => encoreHost.sound.devices();
String get desktopDevice => encoreHost.sound.device;
Future<void> setDesktopDevice(String id) => encoreHost.sound.setDevice(id);
(String, String) desktopOutput() => encoreHost.sound.output();
Future<void> openKdeSettings(String which) => encoreHost.sound.openSettings(which);

// ── Shared with the desktop app (from its desktop_audio.dart) ──

/// An output device: mpv's name for it, what to call it, and speaker / bluetooth / headphones / tv / other.
class OutputDevice {
  const OutputDevice(this.id, this.name, this.kind);
  final String id, name, kind;
}

/// The equalizer's bands (the same five centres Android's equalizer uses, so saved gains mean the same).
const eqCentres = [60.0, 230.0, 910.0, 3600.0, 14000.0];

const eqMinDb = -15.0, eqMaxDb = 15.0;

class EqBand {
  EqBand(this.centerFrequency, double gain, this._apply) : _gain = StreamController<double>.broadcast() {
    _now = gain;
  }
  final double centerFrequency;
  final Future<void> Function(double) _apply;
  final StreamController<double> _gain;
  late double _now;

  double get gain => _now;
  Stream<double> get gainStream => _gain.stream;
  Future<void> setGain(double g) async {
    _now = g;
    _gain.add(g);
    await _apply(g);
  }
}

class EqParams {
  EqParams(this.minDecibels, this.maxDecibels, this.bands);
  final double minDecibels, maxDecibels;
  final List<EqBand> bands;

  factory EqParams.android(AndroidEqualizerParameters p) => EqParams(p.minDecibels, p.maxDecibels, [
        for (final b in p.bands) EqBand(b.centerFrequency, b.gain, b.setGain),
      ]);

  /// The desktop's bands hold the gains; the screen saves them to Settings, which re-applies the filter.
  factory EqParams.desktop(List<double> gains) => EqParams(eqMinDb, eqMaxDb, [
        for (var i = 0; i < eqCentres.length; i++)
          EqBand(eqCentres[i], i < gains.length ? gains[i] : 0.0, (_) async {}),
      ]);
}
