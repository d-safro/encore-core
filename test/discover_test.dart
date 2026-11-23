import 'dart:convert';
import 'dart:io';

import 'package:encore_core/core/appearance.dart';
import 'package:encore_core/core/settings.dart';
import 'package:encore_core/data/ai.dart';
import 'package:encore_core/data/db.dart';
import 'package:encore_core/data/library.dart';
import 'package:encore_core/data/subsonic.dart';
import 'package:encore_core/ui/screens/discover.dart';
import 'package:encore_core/ui/screens/radio.dart' show discoveriesProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A server whose AudioMuse-AI passthrough answers [status] (404: it has none, like Navidrome).
SubsonicClient _server(int status, {bool forYou = false}) => SubsonicClient(
  const Credentials('https://music.test', 'me', 'pw'),
  httpClient: MockClient((req) async {
    if (req.url.path.endsWith('getOpenSubsonicExtensions')) {
      return http.Response(
        jsonEncode({
          'subsonic-response': {
            'status': 'ok',
            'openSubsonicExtensions': [
              if (forYou) {'name': 'encore.forYou', 'versions': [1]},
            ],
          },
        }),
        200,
      );
    }
    if (!req.url.path.contains('/rest/audiomuse/')) return http.Response('', 404);
    if (status != 200) return http.Response(jsonEncode({'error': "AudioMuse-AI isn't set up on this server"}), status);
    return http.Response(req.url.path.endsWith('top_queries') ? '{"queries": []}' : '[]', 200);
  }),
);

/// Conductor without AudioMuse-AI's analysis ready: [audiomuse] is what its passthrough answers, [extensionsDown]
/// how many times the extension list doesn't come before it does. Its own mix has one song.
SubsonicClient _conductor({required int audiomuse, int extensionsDown = 0}) => SubsonicClient(
  const Credentials('https://music.test', 'me', 'pw'),
  httpClient: MockClient((req) async {
    Map<String, dynamic> ok(Map<String, dynamic> body) => {
      'subsonic-response': {'status': 'ok', ...body},
    };
    if (req.url.path.endsWith('getOpenSubsonicExtensions')) {
      if (extensionsDown-- > 0) throw http.ClientException('no route to host');
      return http.Response(
        jsonEncode(
          ok({
            'openSubsonicExtensions': [
              {'name': 'formPost', 'versions': [1]},
              {'name': 'encore.forYou', 'versions': [1]},
            ],
          }),
        ),
        200,
      );
    }
    if (req.url.path.endsWith('getForYou')) {
      return http.Response(
        jsonEncode(
          ok({
            'forYou': {
              'song': [
                {'id': 's1', 'title': 'A made-up tune'},
              ],
            },
          }),
        ),
        200,
      );
    }
    if (req.url.path.contains('/rest/audiomuse/')) {
      return audiomuse == 200 ? http.Response('[]', 200) : http.Response('{"error": "AudioMuse is down"}', audiomuse);
    }
    return http.Response('', 404);
  }),
);

void main() {
  late Directory tmp;
  late LibraryDb db;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('discover');
    await databaseFactory.setDatabasesPath(tmp.path);
    db = await LibraryDb.open(file: 'd.db');
  });
  tearDownAll(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  test('a server without AudioMuse-AI says so; one with it, or no answer, counts as having it', () async {
    expect(await _server(404).offersAudiomuse(), isFalse);
    expect(await _server(200).offersAudiomuse(), isTrue);
    expect(await _server(502).offersAudiomuse(), isTrue);
    final away = SubsonicClient(
      const Credentials('https://music.test', 'me', 'pw'),
      httpClient: MockClient((_) async => throw http.ClientException('no route to host')),
    );
    expect(await away.offersAudiomuse(), isTrue);
  });

  Widget app(SubsonicClient c) => ProviderScope(
    overrides: [
      aiProvider.overrideWithValue(Ai(c, Repo(c, db, false, const Settings()))),
      discoveriesProvider.overrideWith((ref) async => const []),
    ],
    child: MaterialApp(
      theme: ThemeData(extensions: [AppLook.from(const Settings())]),
      home: const DiscoverScreen(),
    ),
  );

  testWidgets("the server's own Made for you: a moment without an answer isn't kept as \"it has none\"", (tester) async {
    final c = _conductor(audiomuse: 404, extensionsDown: 1);
    final box = ProviderContainer(overrides: [aiProvider.overrideWithValue(Ai(c, Repo(c, db, false, const Settings())))]);
    addTearDown(box.dispose);
    final sub = box.listen(forYouOfferedProvider, (_, _) {});
    addTearDown(sub.close);
    expect(await box.read(forYouOfferedProvider.future), isFalse, reason: 'no answer yet');
    await tester.pump(const Duration(seconds: 31));
    expect(await box.read(forYouOfferedProvider.future), isTrue, reason: 'asked again');
  });

  testWidgets('no AudioMuse-AI on the server: one card says why, no mixes that only fail', (tester) async {
    await tester.pumpWidget(app(_server(404)));
    await tester.pumpAndSettle();
    expect(find.text('Sound-based mixes need AudioMuse-AI on your server'), findsOneWidget);
    expect(find.text('Made for you'), findsNothing);
    expect(find.text('Moods'), findsNothing);
    expect(find.text('Describe a sound'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with AudioMuse-AI: the mixes are there', (tester) async {
    await tester.pumpWidget(app(_server(200)));
    await tester.pumpAndSettle();
    expect(find.text('Sound-based mixes need AudioMuse-AI on your server'), findsNothing);
    expect(find.text('Made for you'), findsOneWidget);
    expect(find.text('Moods'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Describe a sound'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Describe a sound'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no AudioMuse-AI, but the server makes its own Made for you: that card, and why the rest is missing', (tester) async {
    await tester.pumpWidget(app(_server(404, forYou: true)));
    await tester.pumpAndSettle();
    expect(find.text('Made for you'), findsOneWidget);
    expect(find.textContaining('Today\'s mix from what you play most'), findsOneWidget);
    expect(find.text('Sound-based mixes need AudioMuse-AI on your server'), findsOneWidget);
    expect(find.textContaining('Moods, Describe a sound'), findsOneWidget, reason: 'the card no longer lists Made for you');
    expect(find.text('Moods'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
