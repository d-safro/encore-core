import 'package:encore/core/appearance.dart';
import 'package:encore/core/settings.dart';
import 'package:encore/data/mixes.dart';
import 'package:encore/ui/screens/home.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _json = {
  'kind': [
    {'kind': 'discover', 'name': 'Discover Weekly', 'enabled': true, 'updated': 1763700000000},
    {'kind': 'radar', 'name': 'Release Radar', 'enabled': false, 'updated': 0},
  ],
  'mix': [
    {'kind': 'discover', 'slot': 'discover', 'playlistId': 'p1', 'name': 'Discover Weekly', 'songCount': 30},
    {'kind': 'daily', 'slot': 'daily-1', 'playlistId': 'p2', 'name': 'Daily Mix 1', 'comment': 'A, B and more'},
    {'kind': 'daily', 'slot': 'daily-2', 'playlistId': '', 'name': 'broken'},
  ],
};

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('reads the server answer', () {
    final m = Mixes.fromJson(_json);
    expect(m.mixes.map((x) => x.name), ['Discover Weekly', 'Daily Mix 1']); // no playlist: left out
    expect(m.isOn('discover'), isTrue);
    expect(m.isOn('radar'), isFalse);
    expect(m.isOn('daylist'), isTrue); // not listed: on
    expect(m.kinds.first.updated, isNotNull);
  });

  test('Your mixes goes on Home once, and removing it sticks', () {
    expect(const Settings().homeSections.first, 'yourMixes');
    final old = Settings.fromJson({'homeSections': ['newest', 'playlists']});
    expect(old.homeSections, ['yourMixes', 'newest', 'playlists']);
    final removed = Settings.fromJson({...old.toJson(), 'homeSections': ['newest']});
    expect(removed.homeSections, ['newest']);
  });

  testWidgets('the Home row shows each mix', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [mixesProvider.overrideWith((ref) async => Mixes.fromJson(_json))],
      child: MaterialApp(
        theme: ThemeData(extensions: [AppLook.from(const Settings())]),
        home: const Scaffold(body: SingleChildScrollView(child: MixesShelf())),
      ),
    ));
    await tester.pump();
    expect(find.text('Repertoire'), findsOneWidget); // the shelf's name
    expect(find.text('Your mixes'), findsOneWidget); // and what it is
    expect(find.text('Daily Mix 1'), findsNWidgets(2)); // on the picture and under it
    expect(find.text('A, B and more'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no mixes on the server: no row', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [mixesProvider.overrideWith((ref) async => const Mixes(supported: false))],
      child: const MaterialApp(home: Scaffold(body: MixesShelf())),
    ));
    await tester.pump();
    expect(find.text('Repertoire'), findsNothing);
  });
}
