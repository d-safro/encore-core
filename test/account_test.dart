import 'dart:convert';
import 'dart:io';

import 'package:encore_core/core/settings.dart';
import 'package:encore_core/data/account.dart';
import 'package:encore_core/data/db.dart';
import 'package:encore_core/data/library.dart';
import 'package:encore_core/data/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// No library sync in these tests (it would talk to the server).
class _NoSync extends SyncNotifier {
  @override
  Future<void> sync() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the little server below

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Directory tmp;
  late HttpServer srv;
  late String server;
  late Map<String, String> stored; // the password store
  PlatformException? storeFails; // the password store can't be used (e.g. no keyring service)

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'subsonic-response': {'status': 'ok', 'version': '1.16.1'}}));
      await req.response.close();
    });
    server = 'http://127.0.0.1:${srv.port}';
  });
  tearDownAll(() => srv.close(force: true));

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('account');
    await databaseFactory.setDatabasesPath(tmp.path);
    libraryDb = await LibraryDb.open(); // encore.db, as main() opens it
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    stored = {};
    storeFails = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (storeFails != null) throw storeFails!;
      final args = (call.arguments as Map?) ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return stored[key];
        case 'write':
          stored[key!] = args['value'] as String;
        case 'delete':
          stored.remove(key);
        case 'deleteAll':
          stored.clear();
        case 'readAll':
          return stored;
        case 'containsKey':
          return stored.containsKey(key);
      }
      return null;
    });
  });
  tearDown(() async {
    await libraryDb.close();
    await tmp.delete(recursive: true);
  });

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [syncProvider.overrideWith(_NoSync.new)]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> signIn(ProviderContainer c, String user, [String pass = 'pw']) async {
    await c.read(accountProvider.future);
    await c.read(accountProvider.notifier).signIn(server, user, pass);
  }

  test("signing out of one server brings back the other's settings, not the ones of the server left", () async {
    final c = container();
    await signIn(c, 'a');
    await prefs.setString('queue', 'queue of a');
    await prefs.setString('jamToken', 'jam of a');
    await prefs.setString('localAddress', 'home of a');
    await prefs.setStringList('pendingScrobbles', ['scrobble of a']);
    await signIn(c, 'b');
    expect(prefs.getString('queue'), isNull);
    await prefs.setString('queue', 'queue of b');
    final a = (await savedAccounts()).firstWhere((x) => x.user == 'a');
    await c.read(accountProvider.notifier).switchTo(a);
    expect(prefs.getString('queue'), 'queue of a');

    await c.read(accountProvider.notifier).signOut();
    expect(c.read(accountProvider).value?.username, 'b');
    expect(prefs.getString('queue'), 'queue of b');
    expect(prefs.getString('jamToken'), isNull);
    expect(prefs.getString('localAddress'), isNull);
    expect(prefs.getStringList('pendingScrobbles'), isNull);
    expect(prefs.getKeys().where((k) => k.contains('@')), isEmpty); // nothing of a's kept aside either
  });

  test("after signing out of the last server, another server doesn't get its downloads", () async {
    final c = container();
    await signIn(c, 'a');
    expect(libraryDb.file, 'encore.db');
    await libraryDb.addDownload(const Song(id: 's1', title: 'One'), '/music/s1.mp3', 1000);
    await c.read(accountProvider.notifier).signOut();
    expect(c.read(accountProvider).value, isNull);

    await signIn(c, 'c');
    expect(libraryDb.file, isNot('encore.db'));
    expect(await libraryDb.downloads(), isEmpty);
    await c.read(accountProvider.notifier).signOut();

    await signIn(c, 'a'); // its downloads stayed on the device for it
    expect(libraryDb.file, 'encore.db');
    expect([for (final (s, _, _) in await libraryDb.downloads()) s.id], ['s1']);
  });

  test('signing in again to the same server (a new password) uses the new password and keeps the queue', () async {
    final c = container();
    await signIn(c, 'a', 'old');
    await prefs.setString('queue', 'queue of a');
    var left = 0;
    await c.read(accountProvider.notifier).signIn(server, 'a', 'new', beforeSwitch: () async => left++);
    expect(c.read(accountProvider).value?.password, 'new');
    expect([for (final x in await savedAccounts()) x.pass], ['new']);
    expect(stored['pass'], 'new');
    expect(left, 0); // the player wasn't stopped (and its queue isn't restored on top of itself)
    expect(prefs.getString('queue'), 'queue of a');
    expect(libraryDb.file, 'encore.db');
  });

  test('no keyring service: nothing saved is read, and signing in says what to install', () async {
    storeFails = PlatformException(code: 'Libsecret error', message: 'The name org.freedesktop.secrets was not provided');
    final c = container();
    expect(await c.read(accountProvider.future), isNull);
    expect(await currentDbFile(), 'encore.db');
    expect(await savedAccounts(), isEmpty);
    await expectLater(
      c.read(accountProvider.notifier).signIn(server, 'a', 'pw'),
      throwsA(isA<KeyringUnavailable>().having((e) => '$e', 'message', contains('install gnome-keyring or KWallet'))),
    );
    expect(c.read(accountProvider).value, isNull);
  });
}
