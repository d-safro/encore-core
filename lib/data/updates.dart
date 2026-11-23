import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/platform.dart';
import '../core/settings.dart';
import '../core/host.dart';

/// Updates come from the app's GitHub releases (EncoreHost.updateRepo: d-safro/encore for the phone,
/// d-safro/encore-desktop for the desktop). Only GitHub is asked (no account, nothing about you is sent).
String get updateRepo => encoreHost.updateRepo;
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
    this.flatpakUrl = '',
  });
  // apkUrl / apkName: the file this device installs (the APK; on Linux the .tar.gz; on Windows the setup
  // program). rpmUrl / debUrl / archUrl / flatpakUrl: the system packages and the Flatpak, for a copy installed
  // that way.
  final String version, notes, apkUrl, apkName, sumsUrl, pageUrl, rpmUrl, debUrl, archUrl, flatpakUrl;
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

/// The Flatpak (encore-1.12.0-x86_64.flatpak), for a copy installed from one.
String? pickFlatpak(List<String> names, String arch) => names
    .where((n) => RegExp('^encore-[0-9][^/]*-${RegExp.escape(arch)}\\.flatpak\$').hasMatch(n))
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
    flatpakUrl: linux ? urlOf(pickFlatpak(names, _arch())) : '',
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

/// The checksum SHA256SUMS.txt gives for [name] (lower case), or null when it has no line for it.
String? checksumFor(String sums, String name) {
  for (final l in const LineSplitter().convert(sums)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(l.trim());
    if (m != null && m.group(2)!.trim() == name) return m.group(1)!.toLowerCase();
  }
  return null;
}

/// Where the update is downloaded to: a folder only you can read. Android: the app's own cache (the
/// installer is given it from there: res/xml/update_paths.xml). The desktop: the app's own folder in your
/// home, not the shared /tmp, where another user could take the name first or swap the file.
Future<Directory> _updatesDir() async {
  final base = isDesktop ? await getApplicationSupportDirectory() : await getTemporaryDirectory();
  final dir = Directory('${base.path}/updates');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  if (isDesktop && !Platform.isWindows) await Process.run('chmod', ['700', dir.path]);
  return dir;
}

/// The update screen was closed while downloading: the download stopped and its part was deleted.
class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
  @override
  String toString() => 'The download was cancelled';
}

/// Downloads the APK (progress 0..1), checks it against the release's SHA256SUMS.txt, and returns the file.
/// A release with no checksum for the file is refused: an unchecked download is never installed. [cancelled]:
/// asked as the download goes; when it says yes the download stops (throwing [UpdateDownloadCancelled]). A
/// download that stops or fails leaves no part of the file behind.
Future<File> downloadUpdate(
  UpdateInfo u,
  void Function(double) onProgress, {
  String? url,
  bool Function()? cancelled,
}) async {
  if (u.sumsUrl.isEmpty) throw const FormatException("This release has no checksum, so the download can't be checked");
  final dir = await _updatesDir();
  // (another of the release's files: a .deb, .rpm or Arch package for a copy the system installed)
  final name = url == null ? u.apkName : Uri.parse(url).pathSegments.last;
  final fileUrl = url ?? u.apkUrl;
  final file = File('${dir.path}/$name');
  final client = http.Client();
  try {
    final sums = await client.get(Uri.parse(u.sumsUrl));
    if (sums.statusCode != 200) throw HttpException("Couldn't get the release's checksums (${sums.statusCode})");
    final want = checksumFor(utf8.decode(sums.bodyBytes, allowMalformed: true), name);
    if (want == null) throw const FormatException("The release's checksums don't list this file");
    final res = await client.send(http.Request('GET', Uri.parse(fileUrl)));
    if (res.statusCode != 200) throw HttpException('Download failed (${res.statusCode})');
    final total = res.contentLength ?? u.size;
    final sink = file.openWrite();
    var got = 0;
    try {
      await for (final chunk in res.stream) {
        if (cancelled?.call() ?? false) throw const UpdateDownloadCancelled();
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress(got / total);
      }
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await file.exists()) await file.delete();
      rethrow;
    }
    await sink.close();
    final have = (await sha256.bind(file.openRead()).first).toString();
    if (want != have) {
      await file.delete();
      throw const FormatException("The download doesn't match the release's checksum");
    }
    return file;
  } finally {
    client.close();
  }
}

/// Whether this copy can install an update itself (see EncoreHost.updates).
Future<bool> canInstallUpdates() => encoreHost.updates.canInstall();

/// Android's "Install unknown apps" page for Encore.
Future<void> allowInstalls() => encoreHost.updates.allowInstalls();

/// Installs the downloaded file: Android's installer (it asks you to confirm), or on the desktop the new
/// version in place of this one; the app then restarts (see EncoreHost.updates).
Future<void> installUpdate(File f) => encoreHost.updates.install(f);

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

// ── Copies installed by the system's package manager ──

/// How a Linux system package was installed: 'flatpak' (Encore runs in a Flatpak), 'deb' (apt), 'arch' (pacman)
/// or 'rpm' (dnf).
String linuxPackageKind({String root = ''}) {
  if (File('$root/.flatpak-info').existsSync()) return 'flatpak';
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
/// The release's package for a copy the system installed: its download address, or null when it has none.
String? systemPackageUrl(UpdateInfo u, String kind) {
  final url = switch (kind) {
    'deb' => u.debUrl,
    'arch' => u.archUrl,
    'flatpak' => u.flatpakUrl,
    _ => u.rpmUrl,
  };
  return url.isEmpty ? null : url;
}

String? systemUpdateCommand(UpdateInfo u, String kind) {
  switch (kind) {
    case 'deb':
      if (u.debUrl.isEmpty) return null;
      final file = Uri.parse(u.debUrl).pathSegments.last;
      return 'cd "\$(mktemp -d)" && curl -LO ${u.debUrl} && sudo apt install ./$file';
    case 'arch':
      // pacman checks signatures of packages it downloads itself, and this one isn't signed: download it first
      if (u.archUrl.isEmpty) return null;
      final file = Uri.parse(u.archUrl).pathSegments.last;
      return 'cd "\$(mktemp -d)" && curl -LO ${u.archUrl} && sudo pacman -U ./$file';
    case 'flatpak':
      // run on the computer, outside Encore: no password for a copy installed for you alone
      if (u.flatpakUrl.isEmpty) return null;
      final file = Uri.parse(u.flatpakUrl).pathSegments.last;
      return 'cd "\$(mktemp -d)" && curl -LO ${u.flatpakUrl} && flatpak install -y ./$file';
    default:
      return u.rpmUrl.isEmpty ? null : 'sudo dnf install ${u.rpmUrl}';
  }
}

/// What the package manager is called, for the update screen.
String packageManagerName(String kind) => switch (kind) {
  'deb' => 'apt',
  'arch' => 'pacman',
  'flatpak' => 'Flatpak',
  _ => 'dnf',
};
