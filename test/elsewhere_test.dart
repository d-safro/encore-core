// "Now playing elsewhere" on Home: your other devices playing now (from the devices list) and other people on the
// server (getNowPlaying, when it shares it); asked again on the event stream's `nowPlaying` event, else every
// 90 s; hidden when nothing plays elsewhere; rounded rectangles that follow Corners; read out as one sentence each;
// the phone's row and the desktop's grid; tap one to see the song and play it here.
import 'dart:async';
import 'dart:convert';

import 'package:encore_core/core/appearance.dart';
import 'package:encore_core/core/settings.dart';
import 'package:encore_core/data/account.dart';
import 'package:encore_core/data/devices.dart';
import 'package:encore_core/data/elsewhere.dart';
import 'package:encore_core/data/events.dart';
import 'package:encore_core/data/library.dart' show offlineProvider;
import 'package:encore_core/data/models.dart';
import 'package:encore_core/data/subsonic.dart';
import 'package:encore_core/ui/screens/elsewhere.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _entry(String id, String title, String user, {String player = 'Feishin', int ago = 0}) => {
  'id': id, 'title': title, 'artist': 'Beta', 'artistId': 'ar-1', 'album': 'Second', 'albumId': 'al-1',
  'coverArt': 'al-1', 'duration': 200, 'username': user, 'playerName': player, 'minutesAgo': ago, 'playerId': 0,
};

/// A pretend server's getNowPlaying, from [entries]; counts how often it's asked.
class FakeServer {
  FakeServer({this.shares = true});
  bool shares;
  int asked = 0;
  List<Map<String, dynamic>> entries = [
    _entry('t1', 'Mine elsewhere', 'me', player: 'Encore'),
    _entry('t2', 'Older', 'dana', ago: 6),
    _entry('t3', 'Newer', 'dana', ago: 1), // the same person's app twice: the newest
    _entry('t4', 'Theirs', 'Sam', player: '', ago: 2),
  ];

  http.Client get client => MockClient((req) async {
    final method = req.url.pathSegments.last;
    if (method != 'getNowPlaying') {
      return http.Response(jsonEncode({'subsonic-response': {'status': 'ok'}}), 200);
    }
    asked++;
    if (!shares) {
      return http.Response(
        jsonEncode({'subsonic-response': {'status': 'failed', 'error': {'code': 50, 'message': 'Not allowed'}}}),
        200,
      );
    }
    return http.Response(
      jsonEncode({'subsonic-response': {'status': 'ok', 'nowPlaying': {'entry': entries}}}),
      200,
    );
  });
}

SubsonicClient _client(FakeServer s) =>
    SubsonicClient(const Credentials('http://conductor.test', 'me', 'pw'), httpClient: s.client);

class FakeEvents {
  final streams = <StreamController<List<int>>>[];
  Future<Stream<List<int>>> connect(String? last) async {
    final c = StreamController<List<int>>();
    streams.add(c);
    return c.stream;
  }

  void send(String text) => streams.last.add(utf8.encode(text));
  void hello(List<String> events) =>
      send('id: a-1\nevent: hello\ndata: ${jsonEncode({'keepalive': 20, 'resumed': false, 'events': events})}\n\n');
}

/// The devices list as given (nothing asked of the server).
class FakeDevices extends DevicesNotifier {
  FakeDevices(this.list);
  final List<RemoteDevice> list;
  @override
  DevicesState build() => DevicesState(supported: true, devices: list);
}

RemoteDevice _device(String id, String name, {bool online = true, bool playing = true, String song = 'k1'}) => RemoteDevice(
  id,
  name,
  'computer',
  online,
  RemoteState(songId: song, title: 'In the kitchen', artist: 'Gamma', album: 'Third', playing: playing, queue: [song]),
);

Future<void> _until(bool Function() ok) async {
  for (var i = 0; i < 200 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ok(), isTrue);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('who is playing what', () {
    test('the call reads getNowPlaying leniently', () async {
      final s = FakeServer();
      s.entries.add({'title': 'no id'});
      final got = await _client(s).nowPlaying();
      expect(got.map((e) => e.song.title), ['Mine elsewhere', 'Older', 'Newer', 'Theirs']);
      expect((got[1].user, got[1].player, got[1].minutesAgo, got[1].song.albumId), ('dana', 'Feishin', 6, 'al-1'));
      expect(NowPlayingEntry.fromJson('nope'), isNull);
    });

    ProviderContainer container(FakeServer s, {LiveEvents? live, List<RemoteDevice> devices = const []}) {
      final c = ProviderContainer(
        overrides: [
          clientProvider.overrideWithValue(_client(s)),
          offlineProvider.overrideWithValue(false),
          liveEventsProvider.overrideWithValue(live),
          devicesProvider.overrideWith(() => FakeDevices(devices)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('other people only (not you), one per app, the newest first', () async {
      final c = container(FakeServer());
      final sub = c.listen(othersPlayingProvider, (_, _) {});
      addTearDown(sub.close);
      final got = await c.read(othersPlayingProvider.future);
      expect(got.map((e) => '${e.user}: ${e.song.title}'), ['dana: Newer', 'Sam: Theirs']);
    });

    test('a server that doesn\'t share it: no one, quietly', () async {
      final c = container(FakeServer(shares: false));
      final sub = c.listen(othersPlayingProvider, (_, _) {});
      addTearDown(sub.close);
      expect(await c.read(othersPlayingProvider.future), isEmpty);
    });

    test('your devices playing now first, then other people; none: nothing', () async {
      final c = container(
        FakeServer(),
        devices: [
          _device('d1', 'Kitchen'),
          _device('d2', 'Paused one', playing: false),
          _device('d3', 'Gone', online: false),
          _device('d4', 'Silent', song: ''),
        ],
      );
      final sub = c.listen(playingElsewhereProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(othersPlayingProvider.future);
      final items = c.read(playingElsewhereProvider);
      expect(items.map((i) => i.where), ['Kitchen', 'dana · Feishin', 'Sam']);
      expect(items.first.mine, isTrue);
      expect(items.first.spoken, 'In the kitchen by Gamma, playing on your Kitchen');
      expect(items[1].spoken, 'dana is listening to Newer by Beta');

      final none = container(FakeServer()..entries = [_entry('t1', 'Mine', 'me')]);
      final sub2 = none.listen(playingElsewhereProvider, (_, _) {});
      addTearDown(sub2.close);
      await none.read(othersPlayingProvider.future);
      expect(none.read(playingElsewhereProvider), isEmpty);
    });

    test('a nowPlaying event looks again (once for a burst); other events don\'t', () async {
      final s = FakeServer();
      final events = FakeEvents();
      final live = LiveEvents(events.connect);
      addTearDown(live.stop);
      live.start();
      final c = container(s, live: live);
      final sub = c.listen(othersPlayingProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(othersPlayingProvider.future);
      expect(s.asked, 1);
      await _until(() => events.streams.isNotEmpty);
      events.hello(['hello', 'nowPlaying']);
      events.send('id: a-2\nevent: playlist\ndata: {"id":"p"}\n\n');
      await Future<void>.delayed(elsewhereSettle + const Duration(milliseconds: 200));
      expect(s.asked, 1);

      s.entries = [_entry('t9', 'Changed', 'dana')];
      for (var i = 0; i < 3; i++) {
        events.send('id: a-${3 + i}\nevent: nowPlaying\ndata: {}\n\n');
      }
      await _until(() => c.read(othersPlayingProvider).value?.first.song.title == 'Changed');
      expect(s.asked, 2);
    });
  });

  testWidgets('with no event stream, asked again every 90 s', (tester) async {
    final s = FakeServer();
    final c = ProviderContainer(
      overrides: [
        clientProvider.overrideWithValue(_client(s)),
        offlineProvider.overrideWithValue(false),
        liveEventsProvider.overrideWithValue(null),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(othersPlayingProvider, (_, _) {});
    addTearDown(sub.close);
    await tester.pump();
    expect(s.asked, 1);
    await tester.pump(elsewherePollEvery - const Duration(seconds: 1));
    expect(s.asked, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(s.asked, 2);
  });

  group('on Home', () {
    final dana = NowPlayingEntry(
      const Song(id: 't3', title: 'Newer', artist: 'Beta', artistId: 'ar-1', albumId: 'al-1'),
      'dana',
      'Feishin',
      1,
    );
    final items = [
      PlayingElsewhere.device(_device('d1', 'Kitchen'), const Song(id: 'k1', title: 'In the kitchen', artist: 'Gamma')),
      PlayingElsewhere.person(dana, dana.song),
    ];

    Widget app(List<PlayingElsewhere> list, {Settings settings = const Settings(), bool? phone, double width = 400}) =>
        ProviderScope(
          overrides: [
            clientProvider.overrideWithValue(null),
            playingElsewhereProvider.overrideWith((ref) => list),
          ],
          child: MaterialApp(
            theme: ThemeData(extensions: [AppLook.from(settings)]),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: SingleChildScrollView(child: NowPlayingElsewhereShelf(phone: phone)),
                ),
              ),
            ),
          ),
        );

    testWidgets('hidden when nothing plays elsewhere', (tester) async {
      await tester.pumpWidget(app(const []));
      expect(find.text('Now playing elsewhere'), findsNothing);
      expect(find.byType(ElsewhereTile), findsNothing);
    });

    testWidgets('the phone: a row of tiles; each read out as one sentence', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(app(items, phone: true));
      expect(find.text('Now playing elsewhere'), findsOneWidget);
      expect(find.text('Your devices and others on this server'), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
      expect(find.byType(GridView), findsNothing);
      expect(find.bySemanticsLabel('In the kitchen by Gamma, playing on your Kitchen'), findsOneWidget);
      expect(find.bySemanticsLabel('dana is listening to Newer by Beta'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('the desktop: a grid, more across as the page widens', (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(items, phone: false, width: 1300));
      expect(find.byType(GridView), findsOneWidget);
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect((grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount).crossAxisCount, 4);
      await tester.pumpWidget(app(items, phone: false, width: 700));
      final narrower = tester.widget<GridView>(find.byType(GridView));
      expect((narrower.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount).crossAxisCount, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('rounded rectangles whose corners follow Appearance, never pills', (tester) async {
      double radius() {
        final m = tester.widget<Material>(
          find.descendant(of: find.byType(ElsewhereTile).first, matching: find.byType(Material)).first,
        );
        return m.borderRadius!.resolve(TextDirection.ltr).topLeft.x;
      }

      await tester.pumpWidget(app(items, settings: const Settings(corners: Corners.small)));
      await tester.pumpAndSettle(); // (the theme eases into the new corners)
      final small = radius();
      await tester.pumpWidget(app(items, settings: const Settings(corners: Corners.round)));
      await tester.pumpAndSettle();
      final round = radius();
      expect(small, closeTo(10 * AppLook.cornerScale(Corners.small), 0.01));
      expect(round, closeTo(10 * AppLook.cornerScale(Corners.round), 0.01));
      final h = tester.getSize(find.byType(ElsewhereTile).first).height;
      expect(round, lessThan(h / 2));
    });

    testWidgets('tap one: the song, and playing it here', (tester) async {
      await tester.pumpWidget(app(items, phone: false)); // (both in view)
      await tester.tap(find.byType(ElsewhereTile).last);
      await tester.pumpAndSettle();
      expect(find.text('dana is listening on Feishin · 1 min ago'), findsOneWidget);
      expect(find.text('Play here'), findsOneWidget);
      expect(find.text('Play next'), findsOneWidget);
      expect(find.text('Go to album'), findsOneWidget);
      expect(find.textContaining('Control'), findsNothing); // not one of yours

      Navigator.of(tester.element(find.text('Play here'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ElsewhereTile).first);
      await tester.pumpAndSettle();
      expect(find.text('Playing on your Kitchen'), findsOneWidget);
      expect(find.text('From where it is, and pause it on Kitchen'), findsOneWidget);
      expect(find.text('Control Kitchen'), findsOneWidget);
    });
  });
}
