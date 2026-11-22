import 'dart:convert';
import 'dart:io';

import 'package:encore/core/settings.dart';
import 'package:encore/data/audiobooks.dart';
import 'package:encore/data/book_downloads.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the little file server below (flutter_test answers 400 otherwise)
  late Directory tmp;
  late HttpServer files;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tmp = await Directory.systemTemp.createTemp('books');
    BookDownloadsNotifier.dir = (id) async => Directory('${tmp.path}/$id');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('encore/system'), (_) async => true);
    files = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    files.listen((req) async {
      req.response.add(List.filled(req.uri.path.endsWith('1') ? 3000 : 2000, 7));
      await req.response.close();
    });
  });

  tearDown(() async {
    await files.close(force: true);
    await tmp.delete(recursive: true);
  });

  AbsClient mockAbs({double at = 0}) => AbsClient(const AbsAccount('http://abs', 'tok'), client: MockClient((req) async {
    final body = switch (req.url.path) {
      '/api/items/b1/play' => {
          'id': 's1',
          'currentTime': at,
          'audioTracks': [
            {'startOffset': 0, 'duration': 600, 'contentUrl': 'x', 'mimeType': 'audio/mpeg'},
            {'startOffset': 600, 'duration': 900, 'contentUrl': 'y', 'mimeType': 'audio/mpeg'},
          ],
        },
      '/api/items/b1' => {'id': 'b1', 'media': {'duration': 1500, 'metadata': {'title': 'Dune'}, 'chapters': [{'start': 0, 'end': 1500, 'title': 'One'}]}},
      _ => <String, Object>{},
    };
    return http.Response(jsonEncode(body), 200);
  }));

  test('downloads every file, then plays from the phone', () async {
    const a = AbsAccount('http://abs', 'tok');
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // the play session's addresses point at the little file server
    final abs = mockAbs();
    final real = abs.play;
    final n = c.read(bookDownloadsProvider.notifier);
    await n.download(a, const Book(id: 'b1', title: 'Dune', duration: 1500), client: _Rewrite(abs, 'http://127.0.0.1:${files.port}', real));
    final kept = c.read(bookDownloadsProvider).kept['b1']!;
    expect(kept.tracks.length, 2);
    expect(await File(kept.tracks[1].url).length(), 3000);
    expect(kept.book.chapters.single.title, 'One');
    expect(c.read(bookDownloadsProvider).progress, isEmpty);
    // kept across restarts
    final again = ProviderContainer();
    addTearDown(again.dispose);
    expect(again.read(bookDownloadsProvider).kept['b1']!.tracks[0].start, 0);
    // offline (no account): plays the files on the phone
    List<String>? played;
    await listen(null, kept.book, local: kept.tracks, at: 700, play: (songs, i, pos) async {
      played = songs.map((s) => audiobookUrl(s.id)!).toList();
      expect((i, pos), (1, const Duration(seconds: 100)));
    });
    expect(played!.every((u) => u.startsWith('file://')), isTrue);
    await n.remove('b1');
    expect(c.read(bookDownloadsProvider).kept, isEmpty);
    expect(await Directory('${tmp.path}/b1').exists(), isFalse);
  });

  test('a stopped download keeps nothing', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(bookDownloadsProvider.notifier);
    final abs = mockAbs();
    n.cancel('b1');
    final f = n.download(const AbsAccount('http://abs', 'tok'), const Book(id: 'b1', title: 'Dune'),
        client: _Rewrite(abs, 'http://127.0.0.1:${files.port}', abs.play));
    n.cancel('b1');
    await f;
    expect(c.read(bookDownloadsProvider).kept, isEmpty);
    expect(c.read(bookDownloadsProvider).failed, isEmpty);
  });

  test("downloading a book you're part-way through keeps your place on the server", () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final abs = mockAbs(at: 1234);
    final rw = _Rewrite(abs, 'http://127.0.0.1:${files.port}', abs.play);
    await c.read(bookDownloadsProvider.notifier).download(const AbsAccount('http://abs', 'tok'), const Book(id: 'b1', title: 'Dune', duration: 1500), client: rw);
    expect(c.read(bookDownloadsProvider).kept, contains('b1'));
    expect(rw.closed, [1234]); // the session the download opened is closed where you were, not at 0
  });
}

/// The mocked Audiobookshelf, with its file addresses on the test's file server.
class _Rewrite extends AbsClient {
  _Rewrite(AbsClient inner, this.base, this.real) : _inner = inner, super(inner.a);
  final AbsClient _inner;
  final String base;
  final Future<(String, List<BookTrack>, double)> Function(String) real;
  @override
  Future<(String, List<BookTrack>, double)> play(String id) async {
    final (s, t, at) = await real(id);
    return (s, [for (final (i, x) in t.indexed) BookTrack(x.start, x.duration, '$base/file$i', x.mime)], at);
  }

  @override
  Future<Book> book(String id) => _inner.book(id);
  final closed = <double>[];
  @override
  Future<void> close(String session, double at, double duration) async => closed.add(at);
}
