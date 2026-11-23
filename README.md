<h1 align="center">encore_core</h1>

<p align="center">The shared heart of <a href="https://github.com/d-safro/encore">Encore</a>: everything the phone and desktop apps have in common.</p>

<p align="center">
  <a href="../../tags"><img alt="Latest tag" src="https://img.shields.io/github/v/tag/d-safro/encore-core?label=version"></a>
  <img alt="Flutter package" src="https://img.shields.io/badge/Flutter-package-02569b">
</p>

## What's in it

- **The server client:** Subsonic / OpenSubsonic, plus Conductor's extras.
- **The player:** queue, gapless, sound levelling (ReplayGain), crossfade and Automix, scrobbling, casting.
- **Downloads and offline mode,** lyrics included.
- **Settings,** and sync between your devices.
- **Updates:** finding a new release on GitHub, downloading it with its checksum checked, and the update sheet
  (each app puts the new version in place with its own hook).
- **The screens and widgets both apps show.**

It's a Flutter package, not an app. The apps take it from git at a tag:

| App | Repository |
|---|---|
| Phone and Wear OS | [d-safro/encore](https://github.com/d-safro/encore) |
| Linux and Windows | [d-safro/encore-desktop](https://github.com/d-safro/encore-desktop) |

## The apps' hooks

encore_core never imports either app. Each app's `main()` calls `runEncore(host, args)` (`lib/run.dart`) with
its own `EncoreHost` (`lib/core/host.dart`), and the shared code asks that for what only one app has:

| Hook | Phone | Desktop |
|---|---|---|
| `appVersion`, `updateRepo` | its version, d-safro/encore | its version, d-safro/encore-desktop |
| `beforeStart`, `afterPrefs` | - | mpv, SQLite through FFI, MPRIS; the window |
| `afterPlayer` | the home-screen widget | the tray, saying goodbye to your devices on quit |
| `overrides` | its USB cable link for `usbLinkProvider` | - |
| `desktopShell`, `desktopSettings`, `songDragSource` | - | the window layout (sidebar, player bar, Now Playing), Settings › Desktop, drag and drop |
| `usbCard`, `downloading` | the USB cable card, Android's download notification | - |
| `sound` (`DesktopSound`) | - | mpv's equalizer, volume and output devices |
| `updates` (`UpdateInstaller`) | Android's installer | the archive swap; a .deb, .rpm or Arch package through the system's password window; the Flatpak through the computer's flatpak; the Windows setup program |
| `quitApp` | - | saves the queue and ends the app |

Every hook has a harmless default, so the shared code and its tests run without either app.

## Working on it

```bash
flutter pub get
flutter analyze
flutter test
```

To try a change in an app, clone the app next to this folder and add a `pubspec_overrides.yaml` there:

```yaml
dependency_overrides:
  encore_core:
    path: ../encore-core
```

To release a change: bump `version:` in `pubspec.yaml`, commit, push, and tag it (`git tag v1.1.0 && git push
origin v1.1.0`). Then set `ref:` to the new tag in each app's `pubspec.yaml` and run `flutter pub get` there
(without the override) so its `pubspec.lock` records it.

The fonts (Inter) and icons are the apps' own (their `assets/`): the shared screens use them by name.
