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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the little server below

  test('downloads still work after switching to another server', () async {
    final tmp = await Directory.systemTemp.createTemp('dl');
    addTearDown(() => tmp.delete(recursive: true));
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => tmp.path);
    m.setMockMethodCallHandler(const MethodChannel('encore/system'), (_) async => true);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath(tmp.path);
    libraryDb = await LibraryDb.open(file: 'a.db');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
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
    // switched servers (account.dart): the library file and the downloads start again for that server
    final old = libraryDb;
    libraryDb = await LibraryDb.open(file: 'b.db');
    await old.close();
    c.invalidate(dbProvider);
    c.invalidate(downloadsProvider);
    c.read(downloadsProvider);
    await c.read(downloadsProvider.notifier).loaded;
    await c.read(downloadsProvider.notifier).download([const Song(id: 's1', title: 'One', suffix: 'mp3')]);
    for (var i = 0; i < 50 && !c.read(downloadsProvider.notifier).has('s1'); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(c.read(downloadsProvider.notifier).has('s1'), isTrue);
    await libraryDb.close();
  });
}
