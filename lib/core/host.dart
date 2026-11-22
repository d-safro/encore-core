import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart' show MaterialPage;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../data/models.dart';
import '../playback/sound.dart';

/// What the app around encore_core provides. encore_core is the code the phone app (d-safro/encore) and
/// the desktop app (d-safro/encore-desktop) share; it never imports either of them. Where shared code needs
/// something only one app has (the desktop's window, tray, mpv and layout; the phone's USB cable and
/// Android's download notification), it asks [encoreHost], which each app sets in its main() by passing its
/// own EncoreHost to runEncore (see run.dart).
///
/// Every hook has a harmless default, so the shared code (and its tests) work without an app.
class EncoreHost {
  const EncoreHost();

  /// This app's version, shown in Settings and compared with its releases ("1.9.0").
  String get appVersion => '0.0.0';

  /// The GitHub repository whose releases this app updates from ("owner/name").
  String get updateRepo => 'd-safro/encore';

  /// Riverpod overrides for the app's own versions of shared providers (the phone's usbLinkProvider).
  List<Override> get overrides => const [];

  /// First thing in runEncore, before the settings, databases or player exist (the desktop: mpv, SQLite
  /// through FFI, MPRIS).
  Future<void> beforeStart(List<String> args) async {}

  /// Once the settings are loaded (the desktop: its window).
  Future<void> afterPrefs() async {}

  /// Once the player runs, before the app's first frame (the desktop's tray; the phone's home-screen widget).
  Future<void> afterPlayer(AudioHandler handler, ProviderContainer container) async {}

  /// The desktop's window layout around the pages (sidebar, player bar, Now Playing panel).
  Widget desktopShell({required String location, required Widget child, Widget? banner}) => child;

  /// A page inside the desktop window (the window's own back and forward buttons, so no second back arrow).
  Page<T> desktopPage<T>({LocalKey? key, required Widget child}) => MaterialPage<T>(key: key, child: child);

  /// Music files dropped on the window from the file manager (the desktop).
  Widget fileDropArea(Widget child) => child;

  /// Settings › Desktop.
  Widget desktopSettings() => const SizedBox.shrink();

  /// Settings › Downloads: music over the phone's USB cable.
  Widget usbCard() => const SizedBox.shrink();

  /// Songs dragged from a list onto a playlist, Liked or the queue (the desktop).
  Widget songDragSource({required List<Song> songs, required Widget child}) => child;

  /// Saves what's playing and ends the app (the desktop, after installing an update).
  Future<void> quitApp() async => exit(0);

  /// How many songs are downloading now (the phone: Android's foreground download notification).
  void downloading(int count) {}

  /// The desktop's own sound: mpv's filters, volume and output devices.
  DesktopSound get sound => const NoDesktopSound();

  /// Installs a downloaded update (the APK, the desktop archive or the Windows setup program).
  UpdateInstaller get updates => const NoUpdateInstaller();
}

/// The app's hooks, set by runEncore before anything else runs.
EncoreHost encoreHost = const EncoreHost();

/// Installs updates downloaded by downloadUpdate (data/updates.dart).
abstract class UpdateInstaller {
  const UpdateInstaller();

  /// Whether this copy can put a new version in place itself (Android: "Install unknown apps" allowed; the
  /// desktop: installed in your home folder or by the Windows setup program).
  Future<bool> canInstall();

  /// Asks for that permission (Android's "Install unknown apps" page).
  Future<void> allowInstalls();

  /// Installs [file]: Android's installer, or the desktop's own swap (then the app quits and restarts).
  Future<void> install(File file);
}

class NoUpdateInstaller extends UpdateInstaller {
  const NoUpdateInstaller();
  @override
  Future<bool> canInstall() async => false;
  @override
  Future<void> allowInstalls() async {}
  @override
  Future<void> install(File file) async =>
      throw const FileSystemException('This copy of Encore cannot install updates itself');
}

// ── What the shared screens use, by the names they had before the split ──

/// The desktop's window layout (see [EncoreHost.desktopShell]).
class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key, required this.location, required this.child, this.banner});
  final String location;
  final Widget child;
  final Widget? banner;

  @override
  Widget build(BuildContext context) => encoreHost.desktopShell(location: location, banner: banner, child: child);
}

/// Files dropped on the window (see [EncoreHost.fileDropArea]).
class FileDropArea extends StatelessWidget {
  const FileDropArea({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => encoreHost.fileDropArea(child);
}

/// Settings › Desktop (see [EncoreHost.desktopSettings]).
class DesktopSettings extends StatelessWidget {
  const DesktopSettings({super.key});

  @override
  Widget build(BuildContext context) => encoreHost.desktopSettings();
}

/// The USB cable card (see [EncoreHost.usbCard]).
class UsbCard extends StatelessWidget {
  const UsbCard({super.key});

  @override
  Widget build(BuildContext context) => encoreHost.usbCard();
}

/// See [EncoreHost.songDragSource].
Widget songDragSource({required List<Song> songs, required Widget child}) =>
    encoreHost.songDragSource(songs: songs, child: child);

/// See [EncoreHost.quitApp].
Future<void> quitApp() => encoreHost.quitApp();
