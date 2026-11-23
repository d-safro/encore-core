// "Getting your songs" (Conductor's encore.requests): the client's calls, the list kept fresh (by the event stream's
// `requests` event, else by asking every 30 s), hidden on servers without it, and the screen: its sections, and an
// admin's actions (a user who isn't one sees none).
import 'dart:async';
import 'dart:convert';

import 'package:encore_core/core/appearance.dart';
import 'package:encore_core/core/settings.dart';
import 'package:encore_core/data/account.dart';
import 'package:encore_core/data/events.dart';
import 'package:encore_core/data/requests.dart';
import 'package:encore_core/data/subsonic.dart';
import 'package:encore_core/ui/screens/getting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

Map<String, dynamic> _song(
  String id,
  String title,
  String state, {
  double progress = 0,
  bool trial = false,
  bool kept = true,
  List<String> reasons = const ['heart'],
  List<String> users = const ['me'],
  List<String> actions = const [],
  String? songId,
  String? arrived,
}) => {
  'id': id, 'type': 'song', 'title': title, 'artist': 'Beta', 'artists': ['Beta'], 'album': 'Second',
  'duration': 200, 'state': state, 'progress': progress, 'transfer': '', 'reasons': reasons, 'users': users,
  'trial': trial, 'kept': kept, 'folder': trial ? 'Trial' : 'Songs', 'asked': '2026-11-23T10:00:00Z',
  'searches': 1, 'found': false, 'manual': false, 'upgrading': false, 'note': '', 'query': 'Beta $title',
  'actions': actions, 'songId': ?songId, 'arrived': ?arrived,
};

/// A pretend Conductor: answers the calls the screen makes, from [pending] and [done], and remembers what it was
/// asked.
class FakeConductor {
  FakeConductor({this.offers = true, this.admin = false});
  bool offers, admin;
  final asked = <Uri>[];
  Object? fail; // getRequests fails with this
  late List<Map<String, dynamic>> pending = [
    _song('dz-t-1', 'Looking', 'searching', actions: admin ? ['retry', 'cancel', 'search', 'pick'] : []),
    _song('dz-t-2', 'Moving', 'downloading', progress: 40, trial: true, kept: false, reasons: ['trial']),
    _song('dz-t-3', 'Nowhere', 'notfound', actions: admin ? ['retry', 'cancel', 'setAside', 'search', 'pick'] : []),
  ];
  List<Map<String, dynamic>> done = [
    _song('dz-t-4', 'Here', 'done', songId: 'tr-4', arrived: '2026-11-23T11:00:00Z', progress: 100),
  ];

  int calls(String method) => asked.where((u) => u.path.endsWith('/$method')).length;

  http.Client get client => MockClient((req) async {
    final u = req.method == 'POST' ? req.url.replace(query: req.body) : req.url;
    asked.add(u);
    final method = u.pathSegments.last;
    final p = u.queryParameters;
    Map<String, dynamic> body;
    switch (method) {
      case 'getOpenSubsonicExtensions':
        body = {
          'openSubsonicExtensions': [
            {'name': 'encore.events', 'versions': [1]},
            if (offers) {'name': 'encore.requests', 'versions': [1]},
          ],
        };
      case 'getRequests':
        if (fail != null) return http.Response(jsonEncode({'subsonic-response': {'status': 'failed', 'error': {'code': 0, 'message': '$fail'}}}), 200);
        final states = (p['state'] ?? '').split(',');
        final list = [...pending, ...done].where((r) => states.contains(r['state'])).toList();
        body = {
          'requests': {
            'total': list.length, 'offset': 0, 'onTrial': 1, 'downloadsPaused': false, 'canPick': admin,
            'counts': {'searching': 1, 'queued': 0, 'downloading': 1, 'done': done.length, 'notfound': 1, 'failed': 0, 'setAside': 0},
            'request': list,
          },
        };
      case 'lookupSongs':
        body = {'lookupSongs': {'song': [], 'trialHours': 24, 'perDay': 40, 'usedToday': 31, 'playlistId': 'pl'}};
      case 'retryRequest' || 'setRequestAside' || 'pickRequestFile':
        body = {'request': pending.firstWhere((r) => r['id'] == p['id'])};
      case 'cancelRequest':
        pending.removeWhere((r) => r['id'] == p['id']);
        body = {};
      case 'searchRequestFiles':
        body = {
          'requestFiles': {
            'query': p['query'], 'total': 2,
            'file': [
              {'user': 'peer', 'filename': r'Music\Beta\Second\01 Looking.flac', 'size': 1000, 'name': '01 Looking.flac',
               'folder': 'Second', 'ext': 'flac', 'bitrate': 0, 'length': 200, 'free': true, 'queue': 0, 'speed': 1,
               'match': true, 'titleOk': true, 'artistOk': true, 'sameAlbum': true, 'score': 0.9},
              {'user': 'other', 'filename': r'x\Looking (Live).mp3', 'size': 900, 'name': 'Looking (Live).mp3',
               'folder': 'x', 'ext': 'mp3', 'bitrate': 320, 'length': 210, 'free': false, 'queue': 4, 'speed': 1,
               'match': false, 'titleOk': true, 'artistOk': false, 'sameAlbum': false, 'score': -1},
            ],
          },
        };
      default:
        body = {};
    }
    return http.Response(jsonEncode({'subsonic-response': {'status': 'ok', ...body}}), 200);
  });
}

/// An event stream, fed by the test.
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

SubsonicClient _client(FakeConductor s) =>
    SubsonicClient(const Credentials('http://conductor.test', 'me', 'pw'), httpClient: s.client);

void main() {
  group('the client', () {
    test('reads the list and asks for only the states wanted', () async {
      final s = FakeConductor(admin: true);
      final c = _client(s);
      final l = await c.requests(states: const [RequestState.searching, RequestState.notfound], count: 200);
      final q = s.asked.last.queryParameters;
      expect(q['state'], 'searching,notfound');
      expect(q['count'], '200');
      expect(l.requests.map((r) => r.title), ['Looking', 'Nowhere']);
      expect(l.count(RequestState.downloading), 1);
      expect(l.onTrial, 1);
      expect(l.canPick, isTrue);
      final r = l.requests.first;
      expect(r.state, RequestState.searching);
      expect(r.actions, {'retry', 'cancel', 'search', 'pick'});
      expect(r.onTheWay, isTrue);
      expect(r.asked, DateTime.utc(2026, 11, 23, 10).toLocal());

      final all = await c.requests(states: const [RequestState.downloading, RequestState.done]);
      final moving = all.requests.first;
      expect((moving.state, moving.progress, moving.trial, moving.kept), (RequestState.downloading, 40.0, true, false));
      final here = all.requests.last;
      expect((here.state, here.songId), (RequestState.done, 'tr-4'));
      expect(here.arrived, isNotNull);
    });

    test('anything unknown is read leniently', () {
      final r = ServerRequest.fromJson({'id': 'x', 'state': 'somethingNew', 'progress': 140, 'actions': 'no'});
      expect(r.state, RequestState.unknown);
      expect(r.progress, 100);
      expect(r.actions, isEmpty);
      expect(r.kept, isTrue);
      expect(RequestList.fromJson(const {}).requests, isEmpty);
    });

    test('the actions, the search and the trial budget', () async {
      final s = FakeConductor(admin: true);
      final c = _client(s);
      await c.retryRequest('dz-t-1');
      expect(s.asked.last.queryParameters['id'], 'dz-t-1');
      await c.setRequestAside('dz-t-3', aside: false);
      expect(s.asked.last.queryParameters['aside'], 'false');
      final f = await c.searchRequestFiles('dz-t-1', query: 'beta looking');
      expect(s.asked.last.queryParameters['query'], 'beta looking');
      expect(f.total, 2);
      expect(f.files.first.match, isTrue);
      expect(f.files.last.bitrate, 320);
      await c.pickRequestFile('dz-t-1', f.files.first);
      final q = s.asked.last.queryParameters;
      expect((q['user'], q['file'], q['size']), ('peer', r'Music\Beta\Second\01 Looking.flac', '1000'));
      await c.cancelRequest('dz-t-1');
      expect(s.pending.map((r) => r['id']), isNot(contains('dz-t-1')));
      final t = await c.trialsToday();
      expect((t?.today, t?.perDay, t?.hours), (31, 40, 24.0));
    });
  });

  group('the list kept fresh', () {
    test('not offered (Navidrome, older Conductor): nothing, and nothing asked', () async {
      final s = FakeConductor(offers: false);
      final container = ProviderContainer(overrides: [
        clientProvider.overrideWithValue(_client(s)),
        liveEventsProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(requestsProvider, (_, _) {});
      addTearDown(sub.close);
      expect(await container.read(requestsProvider.future), isNull);
      expect(s.calls('getRequests'), 0);
    });

    test('an event asks again; so does a resync; other events don\'t', () async {
      final s = FakeConductor();
      final events = FakeEvents();
      final live = LiveEvents(events.connect);
      final container = ProviderContainer(overrides: [
        clientProvider.overrideWithValue(_client(s)),
        liveEventsProvider.overrideWithValue(live),
      ]);
      addTearDown(container.dispose);
      addTearDown(live.stop);
      live.start();
      final sub = container.listen(requestsProvider, (_, _) {});
      addTearDown(sub.close);
      final v = await container.read(requestsProvider.future);
      expect(v!.onTheWay.map((r) => r.title), ['Looking', 'Moving']);
      expect(v.missing.map((r) => r.title), ['Nowhere']);
      expect(v.arrived.map((r) => r.title), ['Here']);
      expect(v.trials?.today, 31);
      final before = s.calls('getRequests');
      expect(before, 2); // what's not here, and what arrived

      while (events.streams.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      events.hello(['hello', 'requests']);
      events.send('id: a-2\nevent: playlist\ndata: {"id":"p"}\n\n');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(s.calls('getRequests'), before);
      expect(live.serverEvents, contains('requests'));

      s.pending.removeAt(0);
      events.send('id: a-3\nevent: requests\ndata: {}\n\n');
      await _until(() => container.read(requestsProvider).value!.onTheWay.length == 1);
      expect(s.calls('getRequests'), before + 2);
      events.send('id: a-4\nevent: resync\ndata: {}\n\n');
      await _until(() => s.calls('getRequests') == before + 4);
    });
  });

  group('the screen', () {
    setUp(() {
      // a phone's height and more: every row is built
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1080, 3000);
      view.devicePixelRatio = 1.5;
    });
    tearDown(() {
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    Widget app(FakeConductor s, Widget child) => ProviderScope(
      overrides: [
        clientProvider.overrideWithValue(_client(s)),
        liveEventsProvider.overrideWithValue(null),
      ],
      child: MaterialApp(theme: ThemeData(extensions: [AppLook.from(const Settings())]), home: child),
    );

    testWidgets('its sections, trial or kept, today\'s trials; no actions for a user who isn\'t an admin', (tester) async {
      final s = FakeConductor();
      await tester.pumpWidget(app(s, const GettingScreen()));
      await tester.pumpAndSettle();
      expect(find.text('On their way'), findsOneWidget);
      expect(find.text('Not found'), findsOneWidget);
      expect(find.text('Recently arrived'), findsOneWidget);
      expect(find.text('2 on their way · 1 not found'), findsOneWidget);
      expect(find.text('1 on trial · 31 of 40 trials today'), findsOneWidget);
      expect(find.textContaining('Downloading · 40%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('On trial'), findsOneWidget); // Moving
      expect(find.text('Kept'), findsNWidgets(3));
      expect(find.byTooltip('What to do with it'), findsNothing);
      expect(find.byTooltip('More'), findsOneWidget); // the arrived song's menu
      // what a screen reader says
      expect(
        find.bySemanticsLabel(RegExp(r'^Moving, Beta, Downloading · 40%, on trial, played')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'^Here, .*double tap to play$')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an admin: each one\'s actions, as the server lists them', (tester) async {
      final s = FakeConductor(admin: true);
      await tester.pumpWidget(app(s, const GettingScreen()));
      await tester.pumpAndSettle();
      expect(find.byTooltip('What to do with it'), findsNWidgets(2));
      await tester.tap(find.byTooltip('What to do with it').last); // Nowhere
      await tester.pumpAndSettle();
      expect(find.text('Look again'), findsOneWidget);
      expect(find.text('Set aside'), findsOneWidget);
      expect(find.text('Find another file'), findsOneWidget);
      expect(find.text('Stop getting it'), findsOneWidget);
      expect(find.text('Bring back'), findsNothing);
      final before = s.calls('getRequests');
      await tester.tap(find.text('Set aside'));
      await tester.pumpAndSettle();
      expect(s.calls('setRequestAside'), 1);
      expect(s.asked.lastWhere((u) => u.path.endsWith('setRequestAside')).queryParameters['id'], 'dz-t-3');
      expect(s.calls('getRequests'), before + 2); // and the list again
      expect(find.text('"Nowhere" is set aside'), findsOneWidget);

      // stopping one asks first
      await tester.tap(find.byTooltip('What to do with it').first); // Looking
      await tester.pumpAndSettle();
      expect(find.text('Set aside'), findsNothing); // not one for this one
      await tester.tap(find.text('Stop getting it'));
      await tester.pumpAndSettle();
      expect(find.text('Stop getting it?'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(s.calls('cancelRequest'), 1);
      expect(find.text('Looking'), findsNothing);
    });

    testWidgets('an admin finds another file and picks one', (tester) async {
      final s = FakeConductor(admin: true);
      await tester.pumpWidget(app(s, const GettingScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('What to do with it').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find another file'));
      await tester.pumpAndSettle();
      expect(find.text('Find a file for "Looking"'), findsOneWidget);
      expect(s.asked.lastWhere((u) => u.path.endsWith('searchRequestFiles')).queryParameters['query'], 'Beta Looking');
      expect(find.text('01 Looking.flac'), findsOneWidget);
      expect(find.text('Looking (Live).mp3'), findsOneWidget);
      await tester.tap(find.text('01 Looking.flac'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get it'));
      await tester.pumpAndSettle();
      final q = s.asked.lastWhere((u) => u.path.endsWith('pickRequestFile')).queryParameters;
      expect((q['id'], q['user']), ('dz-t-1', 'peer'));
      expect(find.text('Getting your songs'), findsOneWidget); // back on the list
      expect(find.text('Getting "Looking" from peer'), findsOneWidget);
    });

    testWidgets('nothing asked for: says how songs get here', (tester) async {
      final s = FakeConductor()
        ..pending = []
        ..done = [];
      await tester.pumpWidget(app(s, const GettingScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Nothing on its way'), findsWidgets);
      expect(find.textContaining('Songs you don\'t have show ⬇'), findsOneWidget);
    });

    testWidgets('the server failing: says so, and tries again', (tester) async {
      final s = FakeConductor()..fail = 'database is locked';
      await tester.pumpWidget(app(s, const GettingScreen()));
      await tester.pumpAndSettle();
      expect(find.textContaining('database is locked'), findsOneWidget);
      s.fail = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('On their way'), findsOneWidget);
    });

    testWidgets('not offered: no way in, and the screen says why', (tester) async {
      final s = FakeConductor(offers: false);
      await tester.pumpWidget(app(s, const Scaffold(body: Column(children: [GettingTile()]))));
      await tester.pumpAndSettle();
      expect(find.text('Getting your songs'), findsNothing);
      await tester.pumpWidget(app(FakeConductor(), const Scaffold(body: Column(children: [GettingTile()]))));
      await tester.pumpAndSettle();
      expect(find.text('Getting your songs'), findsOneWidget);
      expect(find.text('2 on their way · 1 not found'), findsOneWidget);
      await tester.pumpWidget(app(FakeConductor(offers: false), const GettingScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Your server doesn\'t say what it\'s getting'), findsOneWidget);
    });

    testWidgets('without requests events, asked again every 30 s while shown', (tester) async {
      final s = FakeConductor();
      await tester.pumpWidget(app(s, const GettingScreen()));
      await tester.pumpAndSettle();
      final before = s.calls('getRequests');
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(s.calls('getRequests'), before + 2);
      // closed: no more
      await tester.pumpWidget(app(s, const SizedBox()));
      await tester.pumpAndSettle();
      final after = s.calls('getRequests');
      await tester.pump(const Duration(seconds: 61));
      expect(s.calls('getRequests'), after);
    });

    testWidgets('readable and labelled: tap targets, contrast (dark)', (tester) async {
      final handle = tester.ensureSemantics();
      final s = FakeConductor(admin: true);
      await tester.pumpWidget(ProviderScope(
        overrides: [clientProvider.overrideWithValue(_client(s)), liveEventsProvider.overrideWithValue(null)],
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark, extensions: [AppLook.from(const Settings())]),
          home: const GettingScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Your On trial playlist'), findsOneWidget);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });

    test('words', () {
      final now = DateTime(2026, 11, 23, 12);
      expect(requestWhen(now.subtract(const Duration(minutes: 5)), now), '5 min ago');
      expect(requestWhen(now.subtract(const Duration(hours: 30)), now), 'yesterday');
      expect(requestWhen(DateTime(2026, 11, 2), now), '2 Nov');
      expect(trialFor(24), 'a day');
      expect(trialFor(72), '3 days');
      expect(trialFor(12), '12 hours');
      expect(requestWhy(ServerRequest.fromJson(const {'id': 'x', 'reasons': ['heart', 'playlist']})), 'hearted, in a playlist');
      expect(gettingSummary(null), 'What your server is getting for you');
      expect(gettingSummary(const RequestsView()), 'Nothing on its way');
    });
  });
}

Future<void> _until(bool Function() f) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!f()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
