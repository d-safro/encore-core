import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:encore/core/settings.dart';
import 'package:encore/data/db.dart';
import 'package:encore/data/library.dart';
import 'package:encore/data/models.dart';
import 'package:encore/data/subsonic.dart';
import 'package:encore/data/account.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the little server below

  late Directory tmp;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('switch');
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => tmp.path);
    m.setMockMethodCallHandler(const MethodChannel('encore/system'), (_) async => true);
    await databaseFactory.setDatabasesPath(tmp.path);
    libraryDb = await LibraryDb.open(file: 'a.db');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() async {
    await libraryDb.close();
    await tmp.delete(recursive: true);
  });

  /// What account.dart does when you switch servers: the other server's library file, providers built again.
  Future<void> switchServer(ProviderContainer c) async {
    final old = libraryDb;
    libraryDb = await LibraryDb.open(file: 'b.db');
    await old.close();
    c.invalidate(dbProvider);
    c.invalidate(downloadsProvider);
    c.invalidate(syncProvider);
  }

  test('downloads still work after switching to another server', () async {
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => srv.close(force: true));
    srv.listen((req) async {
      req.response.add(List.filled(600 * 1024, 1)); // a song (big enough to count as audio)
      await req.response.close();
    });
    final client = SubsonicClient(const Credentials('http://127.0.0.1', 'me', 'pw'), via: 'http://127.0.0.1:${srv.port}');
    final c = ProviderContainer(overrides: [
      clientProvider.overrideWithValue(client),
      offlineProvider.overrideWithValue(false),
      connectivityProvider.overrideWith((ref) => Stream.value([ConnectivityResult.wifi])),
    ]);
    addTearDown(c.dispose);
    c.listen(connectivityProvider, (_, _) {});
    await c.read(connectivityProvider.future);
    await c.read(downloadsProvider.notifier).loaded;
    await switchServer(c);
    c.read(downloadsProvider);
    await c.read(downloadsProvider.notifier).loaded;
    await c.read(downloadsProvider.notifier).download([const Song(id: 's1', title: 'One', suffix: 'mp3')]);
    for (var i = 0; i < 50 && !c.read(downloadsProvider.notifier).has('s1'); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(c.read(downloadsProvider.notifier).has('s1'), isTrue);
  });

  test("a sync still running when you switch servers doesn't fill the new server's library copy", () async {
    final atPlaylists = Completer<void>(), go = Completer<void>();
    final mock = MockClient((req) async {
      final m = req.url.pathSegments.last;
      Map<String, Object> body = switch (m) {
        'getArtists' => {'artists': {'index': [{'artist': [{'id': 'ar1', 'name': 'A'}]}]}},
        'getAlbumList2' => {'albumList2': {'album': []}},
        'search3' => {'searchResult3': {'song': [{'id': 's1', 'title': 'From the first server'}]}},
        'getPlaylists' => {'playlists': {'playlist': [{'id': 'p1', 'name': 'P'}]}},
        'getPlaylist' => {'playlist': {'id': 'p1', 'name': 'P'}},
        _ => {},
      };
      if (m == 'getPlaylist') {
        atPlaylists.complete();
        await go.future;
      }
      return http.Response(jsonEncode({'subsonic-response': {'status': 'ok', ...body}}), 200);
    });
    final client = SubsonicClient(const Credentials('https://a.test', 'me', 'pw'), httpClient: mock);
    final c = ProviderContainer(overrides: [clientProvider.overrideWithValue(client), offlineProvider.overrideWithValue(false)]);
    addTearDown(c.dispose);
    c.read(syncProvider);
    final sync = c.read(syncProvider.notifier).sync();
    await atPlaylists.future; // the first server's sync is fetching its playlists
    await switchServer(c);
    c.read(syncProvider);
    go.complete();
    await sync;
    expect(await libraryDb.allSongs(), isEmpty); // the second server's copy has none of the first's songs
    expect(c.read(syncProvider).running, isFalse);
  });
}
