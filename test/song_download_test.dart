import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:encore/data/song_download.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pretend Navidrome. [ranges]: answers "bytes=N-" with 206 (a song it has converted before); otherwise
/// sends the whole file every time (one it converts while it sends). [dropAfter]: the connection breaks after
/// that many bytes of the next answer (no signal, the app closed).
class FakeServer {
  FakeServer(this.body, {this.ranges = true});
  Uint8List body;
  bool ranges;
  int? dropAfter;
  int status = 200;
  final asked = <String?>[]; // the Range header of every request
  late HttpServer _server;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/rest/stream');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      asked.add(range);
      final res = req.response;
      if (status != 200) {
        res.statusCode = status;
        await res.close();
        return;
      }
      var start = 0;
      final m = RegExp(r'bytes=(\d+)-').firstMatch(range ?? '');
      if (ranges && m != null) {
        start = int.parse(m.group(1)!);
        if (start >= body.length) {
          res.statusCode = 416;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${body.length}');
          await res.close();
          return;
        }
        res.statusCode = 206;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${body.length - 1}/${body.length}');
        res.contentLength = body.length - start;
      } else if (ranges) {
        res.contentLength = body.length;
      } // else: no length, like a song being converted as it's sent
      final out = body.sublist(start);
      final drop = dropAfter;
      dropAfter = null;
      if (drop != null) {
        // send part of the answer, then cut the connection (as a lost signal does)
        final chunked = res.contentLength < 0;
        if (chunked) res.headers.set(HttpHeaders.transferEncodingHeader, 'chunked');
        final socket = await res.detachSocket();
        final bytes = out.sublist(0, drop);
        if (chunked) socket.add('${bytes.length.toRadixString(16)}\r\n'.codeUnits);
        socket.add(bytes);
        if (chunked) socket.add('\r\n'.codeUnits);
        await socket.flush();
        socket.destroy();
        return;
      }
      for (var i = 0; i < out.length; i += 8192) {
        res.add(out.sublist(i, min(i + 8192, out.length)));
      }
      await res.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Uint8List song(int n, {int seed = 1}) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late Directory dir;
  late HttpClient http;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('encore-dl');
    http = HttpClient();
  });
  tearDown(() async {
    http.close(force: true);
    await dir.delete(recursive: true);
  });

  File dest() => File('${dir.path}/song1.opus');
  File part() => File('${dest().path}.part');

  test('downloads a whole song', () async {
    final s = FakeServer(song(300000))..ranges = false;
    await s.start();
    final f = await resumableDownload(http, s.url, dest());
    expect(await f.readAsBytes(), s.body);
    expect(await part().exists(), isFalse);
    await s.stop();
  });

  test('a broken connection keeps what arrived, and the next try asks for only the rest', () async {
    final s = FakeServer(song(300000))..dropAfter = 120000;
    await s.start();
    await expectLater(resumableDownload(http, s.url, dest()), throwsA(anything));
    expect(await part().length(), 120000);
    expect(await dest().exists(), isFalse);
    final f = await resumableDownload(http, s.url, dest());
    expect(await f.readAsBytes(), s.body);
    expect(s.asked.last, 'bytes=120000-');
    await s.stop();
  });

  test("a server that always starts from the beginning: the start is skipped, the rest appended", () async {
    final s = FakeServer(song(300000), ranges: false)..dropAfter = 100000;
    await s.start();
    await expectLater(resumableDownload(http, s.url, dest()), throwsA(anything));
    expect(await part().length(), 100000);
    var most = 0;
    final f = await resumableDownload(http, s.url, dest(), onProgress: (got, _) => most = max(most, got));
    expect(await f.readAsBytes(), s.body);
    expect(most, 300000);
    await s.stop();
  });

  test('if the song came out different, it keeps the matching start and rewrites the rest', () async {
    final s = FakeServer(song(300000), ranges: false)..dropAfter = 150000;
    await s.start();
    await expectLater(resumableDownload(http, s.url, dest()), throwsA(anything));
    final changed = Uint8List.fromList(s.body)..setRange(90000, 300000, song(210000, seed: 2));
    s.body = changed;
    final f = await resumableDownload(http, s.url, dest());
    expect(await f.readAsBytes(), changed);
    await s.stop();
  });

  test('a shorter song than what was kept: cut to size', () async {
    final s = FakeServer(song(300000), ranges: false)..dropAfter = 200000;
    await s.start();
    await expectLater(resumableDownload(http, s.url, dest()), throwsA(anything));
    s.body = s.body.sublist(0, 150000);
    final f = await resumableDownload(http, s.url, dest());
    expect(await f.readAsBytes(), s.body);
    await s.stop();
  });

  test('everything already arrived (the server says the range is past the end)', () async {
    final s = FakeServer(song(50000));
    await s.start();
    await part().writeAsBytes(s.body);
    final f = await resumableDownload(http, s.url, dest());
    expect(await f.readAsBytes(), s.body);
    await s.stop();
  });

  test('a song gone from the server fails for good and its partial file goes', () async {
    final s = FakeServer(song(1000))..status = 404;
    await s.start();
    await part().writeAsBytes([1, 2, 3]);
    await expectLater(
      resumableDownload(http, s.url, dest()),
      throwsA(isA<DownloadFailed>().having((e) => e.permanent, 'permanent', isTrue)),
    );
    expect(await part().exists(), isFalse);
    await s.stop();
  });

  test('a server error is worth another try, and the partial file stays', () async {
    final s = FakeServer(song(1000))..status = 503;
    await s.start();
    await part().writeAsBytes([1, 2, 3]);
    await expectLater(
      resumableDownload(http, s.url, dest()),
      throwsA(isA<DownloadFailed>().having((e) => e.permanent, 'permanent', isFalse)),
    );
    expect(await part().length(), 3);
    await s.stop();
  });

  test('called off part-way: what arrived stays for next time', () async {
    final s = FakeServer(song(8000000));
    await s.start();
    var stop = false;
    await expectLater(
      resumableDownload(http, s.url, dest(), onProgress: (got, _) => stop = got > 50000, cancelled: () => stop),
      throwsA(isA<DownloadCancelled>()),
    );
    final kept = await part().length();
    expect(kept, greaterThan(0));
    final f = await resumableDownload(http, s.url, dest());
    expect(await f.readAsBytes(), s.body);
    expect(s.asked.last, 'bytes=$kept-');
    await s.stop();
  });
}
