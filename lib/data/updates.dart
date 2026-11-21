import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/platform.dart';
import '../core/settings.dart';

/// Updates come from the app's GitHub releases. Only GitHub is asked (no account, nothing about you is sent).
const updateRepo = 'd-safro/encore';
const _system = MethodChannel('encore/system');

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.apkName,
    required this.size,
    required this.sumsUrl,
    required this.pageUrl,
    this.rpmUrl = '',
    this.debUrl = '',
    this.archUrl = '',
  });
  // apkUrl / apkName: the file this device installs (the APK; on Linux the .tar.gz; on Windows the setup
  // program). rpmUrl / debUrl / archUrl: the system packages, for the command a packaged copy shows.
  final String version, notes, apkUrl, apkName, sumsUrl, pageUrl, rpmUrl, debUrl, archUrl;
  final int size;
}

/// "1.10.0" > "1.9.2". Anything after a '-' or '+' is ignored.
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp(r'^v'), '')
      .split(RegExp(r'[-+]'))
      .first
      .split('.')
      .map((x) => int.tryParse(x) ?? 0)
      .toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// The APK that fits this phone: its own processor type when the release has one, else the universal one.
String? pickApk(List<String> names, List<String> abis) {
  for (final abi in abis) {
    for (final n in names) {
      if (n.endsWith('-$abi.apk')) return n;
    }
  }
  for (final n in names) {
    if (n.endsWith('-universal.apk')) return n;
  }
  return null;
}

/// Desktop: the build for this computer, e.g. encore-1.8.0-linux-x86_64.tar.gz (never an APK).
String? pickLinuxAsset(List<String> names, String arch) {
  final want = RegExp('^encore-[0-9][^/]*-linux-${RegExp.escape(arch)}\\.tar\\.gz\$');
  return names.where(want.hasMatch).firstOrNull;
}

/// Desktop: the RPM for this computer, for `dnf install` (encore-1.8.0-1.x86_64.rpm).
String? pickRpm(List<String> names, String arch) =>
    names.where((n) => n.startsWith('encore-') && n.endsWith('.$arch.rpm')).firstOrNull;

/// Debian and Ubuntu name processors their own way (x86_64 is amd64).
String debArch(String arch) => switch (arch) {
  'x86_64' => 'amd64',
  'aarch64' => 'arm64',
  _ => arch,
};

/// Desktop: the .deb for this computer, for `apt install` (encore_1.8.0_amd64.deb).
String? pickDeb(List<String> names, String arch) => names
    .where((n) => RegExp('^encore_[0-9][^/]*_${RegExp.escape(debArch(arch))}\\.deb\$').hasMatch(n))
    .firstOrNull;

/// Desktop: the Arch package for this computer, for `pacman -U` (encore-bin-1.8.0-1-x86_64.pkg.tar.zst).
String? pickArchPackage(List<String> names, String arch) => names
    .where((n) => RegExp('^encore-bin-[0-9][^/]*-${RegExp.escape(arch)}\\.pkg\\.tar\\.zst\$').hasMatch(n))
    .firstOrNull;

/// Windows: the setup program (encore-1.8.0-windows-x64-setup.exe). The portable .zip is never picked: a
/// portable copy is updated by hand.
String? pickWindowsAsset(List<String> names) =>
    names.where(RegExp(r'^encore-[0-9][^/]*-windows-x64-setup\.exe$').hasMatch).firstOrNull;

String _arch() {
  try {
    final m = Process.runSync('uname', ['-m']).stdout.toString().trim();
    return m.isEmpty ? 'x86_64' : m;
  } catch (_) {
    return 'x86_64';
  }
}

Future<List<String>> _abis() async {
  try {
    return ((await _system.invokeMethod<List>('abis')) ?? const []).cast<String>();
  } catch (_) {
    return const ['arm64-v8a'];
  }
}

/// The newest release if it's newer than this app, else null. Throws when GitHub can't be reached.
Future<UpdateInfo?> fetchUpdate() async {
  final r = await http
      .get(
        Uri.https('api.github.com', '/repos/$updateRepo/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'Encore/$appVersion'},
      )
      .timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw HttpException('GitHub answered ${r.statusCode}');
  final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  final version = '${j['tag_name'] ?? ''}'.replaceFirst(RegExp(r'^v'), '');
  if (version.isEmpty || compareVersions(version, appVersion) <= 0) return null;
  final assets = [for (final a in (j['assets'] as List? ?? const [])) (a as Map).cast<String, dynamic>()];
  final names = [for (final a in assets) '${a['name']}'];
  final name = !isDesktop
      ? pickApk(names, await _abis())
      : Platform.isWindows
      ? pickWindowsAsset(names)
      : pickLinuxAsset(names, _arch());
  if (name == null) return null;
  final linux = isDesktop && Platform.isLinux;
  String urlOf(String? n) =>
      n == null ? '' : '${assets.firstWhere((a) => a['name'] == n)['browser_download_url']}';
  final apk = assets.firstWhere((a) => a['name'] == name);
  final sums = assets.where((a) => a['name'] == 'SHA256SUMS.txt').firstOrNull;
  return UpdateInfo(
    version: version,
    notes: '${j['body'] ?? ''}'.trim(),
    apkUrl: '${apk['browser_download_url']}',
    apkName: name,
    size: (apk['size'] as num?)?.toInt() ?? 0,
    sumsUrl: sums == null ? '' : '${sums['browser_download_url']}',
    pageUrl: '${j['html_url'] ?? 'https://github.com/$updateRepo/releases'}',
    rpmUrl: linux ? urlOf(pickRpm(names, _arch())) : '',
    debUrl: linux ? urlOf(pickDeb(names, _arch())) : '',
    archUrl: linux ? urlOf(pickArchPackage(names, _arch())) : '',
  );
}

bool autoUpdateChecks(SharedPreferences p) => p.getBool('updateChecks') ?? true;

/// The automatic check: at most twice a day, and quiet about a version you said to skip.
Future<UpdateInfo?> checkForUpdateQuietly(SharedPreferences p) async {
  if (!autoUpdateChecks(p)) return null;
  final last = DateTime.fromMillisecondsSinceEpoch(p.getInt('updateCheckedAt') ?? 0);
  if (DateTime.now().difference(last) < const Duration(hours: 12)) return null;
  try {
    final u = await fetchUpdate();
    await p.setInt('updateCheckedAt', DateTime.now().millisecondsSinceEpoch);
    if (u == null || p.getString('updateSkipped') == u.version) return null;
    return u;
  } catch (_) {
    return null; // no network: try another time
  }
}

/// Downloads the APK (progress 0..1), checks it against the release's SHA256SUMS.txt, and returns the file.
Future<File> downloadUpdate(UpdateInfo u, void Function(double) onProgress) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final file = File('${dir.path}/${u.apkName}');
  final client = http.Client();
  try {
    final res = await client.send(http.Request('GET', Uri.parse(u.apkUrl)));
    if (res.statusCode != 200) throw HttpException('Download failed (${res.statusCode})');
    final total = res.contentLength ?? u.size;
    final sink = file.openWrite();
    var got = 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress(got / total);
    }
    await sink.close();
    if (u.sumsUrl.isNotEmpty) {
      final sums = await client.get(Uri.parse(u.sumsUrl));
      final line = const LineSplitter()
          .convert(sums.body)
          .firstWhere((l) => l.trim().endsWith(u.apkName), orElse: () => '');
      final want = line.split(RegExp(r'\s+')).first.toLowerCase();
      final have = (await sha256.bind(file.openRead()).first).toString();
      if (want.isEmpty || want != have) {
        await file.delete();
        throw const FormatException("The download doesn't match the release's checksum");
      }
    }
    return file;
  } finally {
    client.close();
  }
}

Future<bool> canInstallUpdates() async {
  if (isDesktop && Platform.isWindows) return windowsInstalledBySetup();
  if (isDesktop) return desktopInstallDir() != null;
  try {
    return await _system.invokeMethod<bool>('canInstall') ?? false;
  } catch (_) {
    return false;
  }
}

/// Android's "Install unknown apps" page for Encore.
Future<void> allowInstalls() => _system.invokeMethod('allowInstalls');

/// Opens Android's installer for the downloaded file (it asks you to confirm). On the desktop: puts the new
/// version in place of this one (see [installDesktopUpdate]); the app then restarts.
Future<void> installUpdate(File f) => !isDesktop
    ? _system.invokeMethod('install', {'path': f.path})
    : Platform.isWindows
    ? installWindowsUpdate(f)
    : installDesktopUpdate(f);

/// Opens a web page in the browser.
Future<void> openUrl(String url) async {
  if (isDesktop && Platform.isWindows) {
    await Process.start('rundll32', ['url.dll,FileProtocolHandler', url], mode: ProcessStartMode.detached);
  } else if (isDesktop) {
    await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
  } else {
    await _system.invokeMethod('openUrl', {'url': url});
  }
}

// ── The desktop app updating itself ──

/// The folder this desktop app runs from, when Encore may replace it itself: installed in your home folder
/// (tools/linux/install.sh). null for an RPM (dnf updates it) or a build run from the source folder.
Directory? desktopInstallDir() {
  final dir = File(Platform.resolvedExecutable).parent;
  final home = Platform.environment['HOME'] ?? '';
  if (home.isEmpty || !dir.path.startsWith('$home/')) return null;
  if (!File('${dir.path}/.encore-install').existsSync()) return null; // put there by install.sh
  return dir;
}

/// Unpacks the downloaded .tar.gz next to the running app and swaps the folders; the new version starts a
/// moment after this one quits.
Future<void> installDesktopUpdate(File tarball) async {
  final dir = desktopInstallDir();
  if (dir == null) throw const FileSystemException('Encore is installed by the system here: update it with its package manager');
  final staging = Directory('${dir.path}.new');
  if (await staging.exists()) await staging.delete(recursive: true);
  await staging.create(recursive: true);
  final r = await Process.run('tar', ['-xzf', tarball.path, '-C', staging.path]);
  if (r.exitCode != 0) throw FileSystemException("Couldn't unpack the update: ${r.stderr}");
  // the archive holds encore-<version>-linux-<arch>/app/…
  final app = (await staging.list(recursive: true).toList())
      .whereType<File>()
      .where((e) => e.path.endsWith('/app/encore'))
      .firstOrNull;
  if (app == null) throw const FormatException("The update doesn't contain the app");
  await File('${app.parent.path}/.encore-install').writeAsString('$appVersion\n');
  final old = Directory('${dir.path}.old');
  if (await old.exists()) await old.delete(recursive: true);
  await dir.rename(old.path); // the running app keeps its open files
  await app.parent.rename(dir.path);
  await staging.delete(recursive: true);
  // the new version starts once this one has quit (only one Encore runs at a time); the caller quits
  await Process.start('sh', ['-c', 'sleep 2; exec "\$0"', '${dir.path}/encore'], mode: ProcessStartMode.detached);
}

// ── Copies installed by the system's package manager ──

/// How a Linux system package was installed: 'deb' (apt), 'arch' (pacman) or 'rpm' (dnf).
String linuxPackageKind({String root = ''}) {
  if (File('$root/var/lib/dpkg/info/encore.list').existsSync()) return 'deb';
  try {
    final local = Directory('$root/var/lib/pacman/local');
    if (local.existsSync() && local.listSync().any((e) => e.path.split('/').last.startsWith('encore-bin-'))) {
      return 'arch';
    }
  } catch (_) {}
  return 'rpm';
}

/// The terminal command that updates a system-installed copy (it asks for your password), or null when the
/// release has no package of that kind.
String? systemUpdateCommand(UpdateInfo u, String kind) {
  switch (kind) {
    case 'deb':
      if (u.debUrl.isEmpty) return null;
      final file = Uri.parse(u.debUrl).pathSegments.last;
      return 'cd /tmp && curl -LO ${u.debUrl} && sudo apt install ./$file';
    case 'arch':
      return u.archUrl.isEmpty ? null : 'sudo pacman -U ${u.archUrl}';
    default:
      return u.rpmUrl.isEmpty ? null : 'sudo dnf install ${u.rpmUrl}';
  }
}

/// What the package manager is called, for the update screen.
String packageManagerName(String kind) => switch (kind) {
  'deb' => 'apt',
  'arch' => 'pacman',
  _ => 'dnf',
};

// ── Windows ──

/// Installed by the setup program (it leaves its uninstaller next to encore.exe), so a new setup program
/// can update it. The portable .zip has none: that copy is updated by hand.
bool windowsInstalledBySetup() =>
    File('${File(Platform.resolvedExecutable).parent.path}\\unins000.exe').existsSync();

/// Runs the downloaded setup program quietly: it closes this copy, puts the new version in place and
/// starts it again (/launch=1, see tools/windows/encore.iss). The caller then quits.
Future<void> installWindowsUpdate(File setup) async {
  await Process.start(
    setup.path,
    ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/launch=1'],
    mode: ProcessStartMode.detached,
  );
}
