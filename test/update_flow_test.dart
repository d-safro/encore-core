import 'dart:convert';
import 'dart:io';

import 'package:encore_core/data/updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// This computer's processor, as the Linux archive names it.
final arch = Process.runSync('uname', ['-m']).stdout.toString().trim();

/// GitHub's answer about the newest release: 9.0.0, with [files] attached so far.
http.Response release(List<String> files) => http.Response(
  jsonEncode({
    'tag_name': 'v9.0.0',
    'body': 'New things',
    'html_url': 'https://example.test/releases/v9.0.0',
    'assets': [
      for (final f in files) {'name': f, 'browser_download_url': 'https://example.test/$f', 'size': 10},
    ],
  }),
  200,
);

String get tarball => 'encore-9.0.0-linux-$arch.tar.gz';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a release whose files are still being attached', () {
    test('is "on its way", not "the newest version"', () async {
      final none = http.runWithClient(fetchUpdate, () => MockClient((_) async => release(['SHA256SUMS.txt'])));
      await expectLater(none, throwsA(isA<UpdateNotReady>().having((e) => e.version, 'version', '9.0.0')));
      final ready = await http.runWithClient(
        fetchUpdate,
        () => MockClient((_) async => release([tarball, 'SHA256SUMS.txt'])),
      );
      expect(ready?.apkName, tarball);
    }, skip: !Platform.isLinux);

    test("the quiet check doesn't wait 12 hours for it: it looks again soon", () async {
      SharedPreferences.setMockInitialValues({});
      final p = await SharedPreferences.getInstance();
      var asked = 0;
      // the first answer: no file yet; the second: it's there
      final client = MockClient((_) async => release([if (asked++ > 0) tarball, 'SHA256SUMS.txt']));
      final u = await http.runWithClient(() => checkForUpdateQuietly(p, retryAfter: Duration.zero), () => client);
      expect(asked, 2);
      expect(u?.version, '9.0.0');
      expect(p.getInt('updateCheckedAt'), isNotNull);

      // never attached while the app runs: not counted as a check, so the next start looks again
      SharedPreferences.setMockInitialValues({});
      final q = await SharedPreferences.getInstance();
      asked = 0;
      final never = MockClient((_) async {
        asked++;
        return release(['SHA256SUMS.txt']);
      });
      expect(await http.runWithClient(() => checkForUpdateQuietly(q, retryAfter: Duration.zero, tries: 3), () => never),
          isNull);
      expect(asked, 3);
      expect(q.getInt('updateCheckedAt'), isNull);
    }, skip: !Platform.isLinux);
  });

  test('a copy unpacked by hand has no package manager to name', () {
    final root = Directory.systemTemp.createTempSync('encore-kind');
    addTearDown(() => root.deleteSync(recursive: true));
    expect(linuxPackageKind(root: root.path, exe: '/home/me/Downloads/encore-9.0.0-linux-x86_64/app/encore'), 'none');
    expect(linuxPackageKind(root: root.path, exe: '/usr/lib64/encore/encore'), 'rpm');
    const u = UpdateInfo(version: '9.0.0', notes: '', apkUrl: '', apkName: '', size: 0, sumsUrl: '', pageUrl: '',
        rpmUrl: 'https://x/encore-9.0.0-1.x86_64.rpm');
    expect(systemUpdateCommand(u, 'none'), isNull); // never `sudo dnf install` on Ubuntu
    expect(systemPackageUrl(u, 'none'), isNull);
    expect(systemUpdateCommand(u, 'rpm'), 'sudo dnf install https://x/encore-9.0.0-1.x86_64.rpm');
  });
}
