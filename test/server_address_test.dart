import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:encore_core/core/settings.dart';
import 'package:encore_core/data/account.dart';
import 'package:encore_core/data/db.dart';
import 'package:encore_core/data/library.dart';
import 'package:encore_core/data/models.dart';
import 'package:encore_core/data/saved_covers.dart';
import 'package:encore_core/data/saved_lyrics.dart';
import 'package:encore_core/data/server_address.dart';
import 'package:encore_core/data/subsonic.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NoSync extends SyncNotifier {
  @override
  Future<void> sync() async {}
}

/// A pretend server: what it says it is, the logins it takes and the songs it has.
class _Server {
  _Server({this.type = 'conductor', this.version = '1.5.0', this.users = const {'a': 'pw', 'b': 'pw'}, this.songs = const {'s1'}});
  final String type, version;
  final Map<String, String> users;
  final Set<String> songs;
  late HttpServer http;
  final asked = <String>[];
  String get url => 'http://127.0.0.1:${http.port}';

  Map<String, Object?> answer(Uri u) {
    final m = u.pathSegments.last;
    asked.add(m);
    final p = u.queryParameters;
    final pass = users[p['u']];
    final ok = pass != null && md5Token(pass, p['s'] ?? '') == p['t'];
    final head = {'version': '1.16.1', 'type': type, 'serverVersion': version, 'openSubsonic': true};
    if (!ok) return {...head, 'status': 'failed', 'error': {'code': 40, 'message': 'Wrong username or password'}};
    return switch (m) {
      'getSong' when songs.contains(p['id']) => {...head, 'status': 'ok', 'song': {'id': p['id'], 'title': 'x'}},
      'getSong' => {...head, 'status': 'failed', 'error': {'code': 70, 'message': 'Song not found'}},
      'getAlbumList2' => {...head, 'status': 'ok', 'albumList2': {'album': [for (final s in songs) {'id': 'al-$s', 'name': s}]}},
      _ => {...head, 'status': 'ok'},
    };
  }

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'subsonic-response': answer(req.uri)}));
      await req.response.close();
    });
  }
}

String md5Token(String pass, String salt) => md5.convert(utf8.encode(pass + salt)).toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real HTTP to the little servers below

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Directory tmp;
  late Map<String, String> stored; // the password store
  final servers = <_Server>[];

  Future<_Server> server([_Server? s]) async {
    final srv = s ?? _Server();
    await srv.start();
    servers.add(srv);
    return srv;
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('address');
    await databaseFactory.setDatabasesPath(tmp.path);
    libraryDb = await LibraryDb.open();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    savedCovers = await SavedCovers.open(Directory('${tmp.path}/covers'));
    savedLyrics = await SavedLyrics.open(Directory('${tmp.path}/lyrics'));
    stored = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
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
    for (final s in servers) {
      await s.http.close(force: true);
    }
    servers.clear();
    await libraryDb.close();
    savedCovers = null;
    savedLyrics = null;
    await tmp.delete(recursive: true);
  });

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [
      syncProvider.overrideWith(_NoSync.new),
      // no Wi-Fi: the home-network address isn't tried
      connectivityProvider.overrideWith((ref) => Stream.value([ConnectivityResult.none])),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> signIn(ProviderContainer c, String at, String user) async {
    await c.read(accountProvider.future);
    await c.read(accountProvider.notifier).signIn(at, user, 'pw');
  }

  /// Two addresses of one server: two pretend servers answering alike.
  Future<(_Server, _Server)> twoAddresses() async => (await server(), await server());

  test('moving to another address of the same server keeps downloads, the library file, queue, pins and settings', () async {
    final (home, public) = await twoAddresses();
    final c = container();
    await signIn(c, home.url, 'a');
    final before = (await savedAccounts()).single;
    expect(before.db, 'encore.db');
    await libraryDb.addDownload(const Song(id: 's1', title: 'One'), '/music/encore/s1.mp3', 1000);
    await prefs.setString('queue', 'queue of a');
    await prefs.setString('libraryPins', 'pins of a');
    await prefs.setString('downloadPins', 'download pins of a');
    await prefs.setStringList('pendingScrobbles', ['scrobble of a']);
    await prefs.setString('syncLast:hearts', 'agreed');
    await prefs.setString('localAddress', 'http://192.168.1.20:4533');
    await savedCovers!.save(home.url, 'al-1', SavedCovers.small, List.filled(100, 1));
    await savedLyrics!.write(home.url, 's1', SavedLyric(lyrics: const Lyrics(), at: DateTime(2026)));
    final passBefore = stored['pass'];

    await c.read(accountProvider.notifier).changeAddress('${public.url}/');

    // the account, wherever it's kept, is at the new address; the password is as it was
    expect(c.read(accountProvider).value?.base, public.url);
    expect(stored['server'], public.url);
    expect(stored['user'], 'a');
    expect(stored['pass'], passBefore);
    final after = (await savedAccounts()).single;
    expect((after.server, after.user, after.pass, after.db), (public.url, 'a', 'pw', 'encore.db'));
    expect(await currentDbFile(), 'encore.db');
    expect(prefs.getString('mainLibraryOwner'), after.id);
    // the client goes to the new address
    expect(c.read(clientProvider)?.base, public.url);
    // nothing else moved
    expect(libraryDb.file, 'encore.db');
    expect([for (final (s, _, _) in await libraryDb.downloads()) s.id], ['s1']);
    expect(prefs.getString('queue'), 'queue of a');
    expect(prefs.getString('libraryPins'), 'pins of a');
    expect(prefs.getString('downloadPins'), 'download pins of a');
    expect(prefs.getStringList('pendingScrobbles'), ['scrobble of a']);
    expect(prefs.getString('syncLast:hearts'), 'agreed');
    expect(prefs.getString('localAddress'), 'http://192.168.1.20:4533');
    // the downloads' covers and lyrics show from the new address
    expect(savedCovers!.file(public.url, 'al-1', SavedCovers.small), isNotNull);
    expect(savedCovers!.file(home.url, 'al-1', SavedCovers.small), isNull);
    expect(await savedLyrics!.read(public.url, 's1'), isNotNull);
    // and the new address was asked whether it has the songs this device has
    expect(public.asked, containsAll(['ping', 'getSong']));
  });

  test("a second account's library file and settings put aside come along, and signing in there again finds them", () async {
    final (home, public) = await twoAddresses();
    final c = container();
    await signIn(c, home.url, 'a');
    await signIn(c, home.url, 'b');
    final b = (await savedAccounts()).firstWhere((x) => x.user == 'b');
    expect(b.db, 'encore-${b.id}.db');
    await libraryDb.addDownload(const Song(id: 's1', title: 'One'), '/music/b/s1.mp3', 1000);
    await prefs.setString('queue', 'queue of b');

    // a's settings are put aside under its id; b moves
    await c.read(accountProvider.notifier).changeAddress(public.url);
    final moved = (await savedAccounts()).firstWhere((x) => x.user == 'b');
    expect((moved.server, moved.db), (public.url, b.db));

    // to a and back: b's queue comes back from where it was put aside under its new id
    await c.read(accountProvider.notifier).switchTo((await savedAccounts()).firstWhere((x) => x.user == 'a'));
    expect(prefs.getString('queue'), isNull);
    expect(prefs.getString('queue@${moved.id}'), 'queue of b');
    await c.read(accountProvider.notifier).switchTo(moved);
    expect(prefs.getString('queue'), 'queue of b');
    expect(libraryDb.file, b.db);

    // signed out of it and in again at the new address: its library file (and downloads) again
    await c.read(accountProvider.notifier).signOut();
    await signIn(c, public.url, 'b');
    expect(libraryDb.file, b.db);
    expect([for (final (s, _, _) in await libraryDb.downloads()) s.id], ['s1']);
    // while the old address, signed in to anew, is another account with a file of its own
    await signIn(c, home.url, 'b');
    expect(libraryDb.file, isNot(b.db));
    expect(await libraryDb.downloads(), isEmpty);
  });

  Future<void> refused(ProviderContainer c, String to, AddressProblem problem, String said) async {
    final acct = c.read(accountProvider).value!;
    final saved = jsonEncode([for (final a in await savedAccounts()) a.toJson()]);
    final keys = {for (final k in prefs.getKeys()) k: prefs.get(k)};
    await expectLater(
      c.read(accountProvider.notifier).changeAddress(to),
      throwsA(isA<AddressRefused>()
          .having((e) => e.problem, 'problem', problem)
          .having((e) => '$e', 'message', contains(said))
          .having((e) => '$e', 'message', isNot(contains('pw')))),
    );
    // nothing changed
    expect(c.read(accountProvider).value?.base, acct.base);
    expect(stored['server'], acct.base);
    expect(jsonEncode([for (final a in await savedAccounts()) a.toJson()]), saved);
    expect({for (final k in prefs.getKeys()) k: prefs.get(k)}, keys);
  }

  test('refuses another server: another kind or version, or without the songs this device has', () async {
    final home = await server();
    final navidrome = await server(_Server(type: 'navidrome', version: '0.53.3'));
    final stranger = await server(_Server(songs: {'other'}));
    final c = container();
    await signIn(c, home.url, 'a');
    await libraryDb.addDownload(const Song(id: 's1', title: 'One'), '/music/s1.mp3', 1000);
    await refused(c, navidrome.url, AddressProblem.otherServer, 'navidrome 0.53.3');
    await refused(c, stranger.url, AddressProblem.otherServer, "doesn't have the songs");
  });

  test('refuses an address where the login is refused, nothing answers, or that is saved already', () async {
    final (home, public) = await twoAddresses();
    final noA = await server(_Server(users: const {'b': 'pw'}));
    final c = container();
    await signIn(c, home.url, 'a');
    await refused(c, noA.url, AddressProblem.loginRefused, "doesn't take your login as a");
    final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final nobody = 'http://127.0.0.1:${closed.port}';
    await closed.close(force: true);
    await refused(c, nobody, AddressProblem.noAnswer, 'Nothing answers there');
    await refused(c, home.url, AddressProblem.same, 'uses already');
    await refused(c, '', AddressProblem.notAnAddress, "isn't a web address");
    // the same login at that address saved as a server of its own
    await signIn(c, public.url, 'a');
    await c.read(accountProvider.notifier).switchTo((await savedAccounts()).firstWhere((x) => x.server == home.url));
    await refused(c, public.url, AddressProblem.alreadySaved, 'sign out of it first');
  });

  group('checkNewAddress', () {
    const creds = Credentials('https://vpn.test', 'a', 'secret');
    ConnectTo fake(Map<String, Object?> Function(String host, String method) answer) => (cr, at) => SubsonicClient(
      cr,
      via: at,
      httpClient: MockClient((req) async {
        final body = answer(req.url.host, req.url.pathSegments.last);
        if (body.containsKey('throw')) throw const SocketException('Connection refused');
        return http.Response(jsonEncode({'subsonic-response': body}), 200);
      }),
    );
    const ok = {'status': 'ok', 'type': 'conductor', 'serverVersion': '1.5.0'};

    test('the same server at both: fine, even when the old address no longer answers', () async {
      await checkNewAddress(creds, 'https://public.test', knownSongs: ['s1'], connect: fake((_, _) => ok));
      await checkNewAddress(creds, 'https://public.test', knownSongs: ['s1'],
          connect: fake((host, _) => host == 'vpn.test' ? {'throw': true} : ok));
    });

    test('with no songs on the device, the newest albums are compared', () async {
      Map<String, Object?> albums(String id) => {...ok, 'albumList2': {'album': [{'id': id, 'name': id}]}};
      await expectLater(
        checkNewAddress(creds, 'https://public.test',
            connect: fake((host, m) => m == 'getAlbumList2' ? albums(host == 'vpn.test' ? 'x' : 'y') : ok)),
        throwsA(isA<AddressRefused>().having((e) => e.problem, 'problem', AddressProblem.otherServer)),
      );
      await checkNewAddress(creds, 'https://public.test', connect: fake((host, m) => m == 'getAlbumList2' ? albums('x') : ok));
    });

    test('something that is no music server', () async {
      SubsonicClient page(Credentials cr, String at) =>
          SubsonicClient(cr, via: at, httpClient: MockClient((_) async => http.Response('<html>', 200)));
      await expectLater(
        checkNewAddress(creds, 'https://public.test', connect: page),
        throwsA(isA<AddressRefused>().having((e) => e.problem, 'problem', AddressProblem.notAServer)),
      );
    });
  });
}
