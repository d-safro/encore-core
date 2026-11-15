import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  });
  final String version, notes, apkUrl, apkName, sumsUrl, pageUrl;
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
  final name = pickApk([for (final a in assets) '${a['name']}'], await _abis());
  if (name == null) return null;
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
  try {
    return await _system.invokeMethod<bool>('canInstall') ?? false;
  } catch (_) {
    return false;
  }
}

/// Android's "Install unknown apps" page for Encore.
Future<void> allowInstalls() => _system.invokeMethod('allowInstalls');

/// Opens Android's installer for the downloaded file (it asks you to confirm).
Future<void> installUpdate(File f) => _system.invokeMethod('install', {'path': f.path});

/// Opens a web page in the browser.
Future<void> openUrl(String url) => _system.invokeMethod('openUrl', {'url': url});
