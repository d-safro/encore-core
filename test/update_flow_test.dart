import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:encore_core/core/host.dart';
import 'package:encore_core/data/updates.dart';
import 'package:encore_core/ui/update.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
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

class _Installer extends UpdateInstaller {
  _Installer(this.done);
  final Future<void> done;
  int installs = 0;
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<void> allowInstalls() async {}
  @override
  Future<void> install(File file) {
    installs++;
    return done;
  }
}

class _Host extends EncoreHost {
  const _Host(this.installer);
  final _Installer installer;
  @override
  UpdateInstaller get updates => installer;
  @override
  Future<void> quitApp() async {}
}

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

  test('only one update runs at a time', () {
    final a = Object(), b = Object();
    expect(claimUpdate(a), isTrue);
    expect(updateRunning, isTrue);
    expect(claimUpdate(b), isFalse);
    expect(claimUpdate(a), isTrue); // the same one again (its "Try again")
    releaseUpdate(b); // not b's to give back
    expect(updateRunning, isTrue);
    releaseUpdate(a);
    expect(updateRunning, isFalse);
    expect(claimUpdate(b), isTrue);
    releaseUpdate(b);
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

  testWidgets('while the new version is put in place the sheet stays, and no second update starts', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('encore-update');
    addTearDown(() => tmp.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tmp.path,
    );
    final installing = Completer<void>();
    final installer = _Installer(installing.future);
    final before = encoreHost;
    encoreHost = _Host(installer);
    addTearDown(() => encoreHost = before);
    final body = utf8.encode('the new version');
    final server = MockClient((req) async {
      final name = req.url.pathSegments.last;
      if (name == 'SHA256SUMS.txt') return http.Response('${sha256.convert(body)}  $tarball\n', 200);
      return http.Response.bytes(body, 200);
    });
    final v = UpdateInfo(
      version: '9.0.0',
      notes: '',
      apkUrl: 'https://example.test/$tarball',
      apkName: tarball,
      size: body.length,
      sumsUrl: 'https://example.test/SHA256SUMS.txt',
      pageUrl: 'https://example.test/',
    );

    await http.runWithClient(() async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        })),
      ));
      unawaited(showUpdateDialog(ctx, v));
      await tester.pumpAndSettle();
      // the download and its checksum are real file work
      await tester.runAsync(() async {
        await tester.tap(find.text('Update'));
        for (var i = 0; i < 100 && installer.installs == 0; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      expect(installer.installs, 1);
      expect(find.text('Installing…'), findsOneWidget);
      expect(find.text('Close'), findsNothing);
      expect(find.text('Cancel'), findsNothing);
      // Escape / back doesn't close it either
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Installing…'), findsOneWidget);
      // the quiet check offering it again meanwhile: nothing else opens
      expect(updateRunning, isTrue);
      unawaited(showUpdateDialog(ctx, v));
      await tester.pumpAndSettle();
      expect(find.text('Encore 9.0.0 is available'), findsNothing);

      // the install fails: the sheet can be closed again, and the update is free for another try
      installing.completeError(const FileSystemException('disk full'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't install the update"), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(updateRunning, isFalse);
    }, () => server);
  }, skip: !Platform.isLinux);
}
