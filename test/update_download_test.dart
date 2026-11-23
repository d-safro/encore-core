import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:encore_core/data/updates.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('updates');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tmp.path,
    );
  });
  tearDown(() async => tmp.delete(recursive: true));

  final body = List<int>.generate(64 * 1024, (i) => i % 251);
  const u = UpdateInfo(
    version: '9.0.0',
    notes: '',
    apkUrl: 'https://example.test/encore-9.0.0-universal.apk',
    apkName: 'encore-9.0.0-universal.apk',
    size: 64 * 1024,
    sumsUrl: 'https://example.test/SHA256SUMS.txt',
    pageUrl: 'https://example.test/',
  );

  /// A release whose file comes in 8 KB pieces; [fail] breaks the connection after the first one.
  http.Client server({bool fail = false}) => MockClient.streaming((req, _) async {
    if (req.url.path.endsWith('SHA256SUMS.txt')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('${sha256.convert(body)}  ${u.apkName}\n')),
        200,
      );
    }
    final pieces = StreamController<List<int>>();
    () async {
      for (var i = 0; i < body.length; i += 8192) {
        if (fail && i > 0) {
          pieces.addError(http.ClientException('Connection reset'));
          break;
        }
        pieces.add(body.sublist(i, i + 8192));
        await Future<void>.delayed(Duration.zero);
      }
      await pieces.close();
    }();
    return http.StreamedResponse(pieces.stream, 200, contentLength: body.length);
  });

  List<FileSystemEntity> left() {
    final d = Directory('${tmp.path}/updates');
    return d.existsSync() ? d.listSync() : const [];
  }

  test('a finished download matches its checksum', () async {
    final f = await http.runWithClient(() => downloadUpdate(u, (_) {}), server);
    expect(await f.readAsBytes(), body);
  });

  test('closing the update screen stops the download and leaves no part of it', () async {
    var closed = false;
    final done = http.runWithClient(
      () => downloadUpdate(u, (p) => closed = true, cancelled: () => closed),
      server,
    );
    await expectLater(done, throwsA(isA<UpdateDownloadCancelled>()));
    expect(left(), isEmpty);
  });

  test('a download that breaks off leaves no part of the file behind', () async {
    final done = http.runWithClient(() => downloadUpdate(u, (_) {}), () => server(fail: true));
    await expectLater(done, throwsA(isA<http.ClientException>()));
    expect(left(), isEmpty);
  });
}
