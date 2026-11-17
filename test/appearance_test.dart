import 'dart:convert';

import 'package:encore/core/appearance.dart';
import 'package:encore/core/settings.dart';
import 'package:encore/ui/screens/appearance.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('looks', () {
    test('a fresh install is the Encore look', () {
      expect(lookOf(const Settings()), Look.encore);
    });

    test('applying each look makes it the current one', () {
      for (final l in Look.values) {
        expect(lookOf(l.applyTo(const Settings())), l, reason: l.label);
      }
    });

    test('every look sets the same options, so switching between them never leaves one behind', () {
      final keys = Look.encore.changes.keys.toSet();
      for (final l in Look.values) {
        expect(l.changes.keys.toSet().difference({'themeSource', 'pureBlack'}), keys, reason: l.label);
      }
    });

    test('looks only touch appearance settings', () {
      for (final l in Look.values) {
        expect(appearanceKeys, containsAll(l.changes.keys), reason: l.label);
      }
    });

    test('pure black alone still counts as the Encore look', () {
      expect(lookOf(const Settings().copyWith({'pureBlack': true})), Look.encore);
    });

    test('changing one option by hand makes it Custom', () {
      final s = Look.compact.applyTo(const Settings()).copyWith({'miniPlayer': 'floating'});
      expect(lookOf(s), isNull);
    });

    test('looks keep personal choices (text size, tabs, Home sections)', () {
      final mine = const Settings().copyWith({
        'textScale': 1.2,
        'navTabs': ['home', 'search'],
        'homeSections': ['playlists'],
      });
      final s = Look.minimal.applyTo(mine);
      expect(s.textScale, 1.2);
      expect(s.navTabs, ['home', 'search']);
      expect(s.homeSections, ['playlists']);
      expect(s.pureBlack, isTrue);
      expect(s.playerLayout, PlayerLayout.minimal);
    });
  });

  group('appearance settings', () {
    test('survive a save and load', () {
      final s = const Settings().copyWith({
        'highContrast': true,
        'fontFamily': 'system',
        'textScale': 1.15,
        'corners': 'round',
        'compact': true,
        'cardSize': 'large',
        'showQuickPills': false,
        'showJumpBackIn': false,
        'showGreeting': false,
        'playerLayout': 'coverLyrics',
        'playerBlur': 'strong',
        'miniPlayer': 'slim',
        'navTabs': ['home', 'library', 'search'],
        'navLabels': 'always',
      });
      final back = Settings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.toJson(), s.toJson());
      expect(back.corners, Corners.round);
      expect(back.playerLayout, PlayerLayout.coverLyrics);
      expect(back.miniPlayer, MiniPlayerStyle.slim);
    });

    test('settings saved by an older version get the standard look', () {
      final old = Settings.fromJson({'pureBlack': true, 'crossfade': 4});
      expect(old.corners, Corners.soft);
      expect(old.navTabs, Settings.defaultNavTabs);
      expect(old.playerLayout, PlayerLayout.bigCover);
      expect(old.crossfade, 4);
    });

    test('bad values are made safe', () {
      final s = Settings.fromJson({
        'navTabs': ['search', 'nope', 'search'],
        'textScale': 9,
        'corners': 'wobbly',
        'fontFamily': 'Comic Sans',
      });
      expect(s.navTabs, ['home', 'search']); // Home always stays, no repeats, unknown tabs dropped
      expect(s.textScale, 1.4);
      expect(s.corners, Corners.soft);
      expect(s.fontFamily, 'inter');
      expect(Settings.fromJson({'navTabs': []}).navTabs, ['home', 'discover']); // at least two
    });

    test('a look is saved and still there after a restart', () {
      final c = ProviderContainer();
      c.read(settingsProvider.notifier).update(Look.artwork.changes);
      c.dispose();
      final saved = jsonDecode(prefs.getString('settings')!) as Map<String, dynamic>;
      expect(saved['cardSize'], 'large');
      final again = ProviderContainer();
      expect(lookOf(again.read(settingsProvider)), Look.artwork);
      expect(again.read(settingsProvider).themeSource, ThemeSource.albumArt);
      again.dispose();
    });

    test('reset to default puts back appearance and nothing else', () {
      final c = ProviderContainer();
      final n = c.read(settingsProvider.notifier);
      n.update({...Look.minimal.changes, 'textScale': 1.3, 'navTabs': ['home', 'search'], 'crossfade': 6});
      n.update(appearanceDefaults());
      final s = c.read(settingsProvider);
      final d = const Settings().toJson();
      for (final k in appearanceKeys) {
        expect(s.toJson()[k], d[k], reason: k);
      }
      expect(s.crossfade, 6); // playback settings are not appearance
      expect(lookOf(s), Look.encore);
      c.dispose();
    });
  });

  group('appearance screen', () {
    Future<ProviderContainer> open(WidgetTester tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final s = c.read(settingsProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: ThemeData(extensions: [AppLook.from(s)]),
            home: const AppearanceScreen(),
          ),
        ),
      );
      return c;
    }

    testWidgets('tapping a look applies it straight away', (tester) async {
      final c = await open(tester);
      expect(find.text('Big artwork'), findsOneWidget);
      await tester.tap(find.text('Minimal'));
      await tester.pump();
      expect(lookOf(c.read(settingsProvider)), Look.minimal);
      expect(c.read(settingsProvider).pureBlack, isTrue);
    });

    testWidgets('changing an option shows Custom', (tester) async {
      final c = await open(tester);
      final page = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
      await tester.scrollUntilVisible(find.text('Slim'), 300, scrollable: page);
      await tester.ensureVisible(find.text('Slim'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Slim'));
      await tester.pump();
      expect(c.read(settingsProvider).miniPlayer, MiniPlayerStyle.slim);
      await tester.scrollUntilVisible(find.textContaining('Custom'), -300, scrollable: page);
      expect(find.textContaining('Custom'), findsOneWidget);
    });

    testWidgets('every look preview draws without overflowing', (tester) async {
      for (final l in Look.values) {
        for (final extra in [<String, Object>{}, {'navLabels': 'always', 'highContrast': true}]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(child: LookPreview(settings: l.applyTo(const Settings()).copyWith(extra))),
            ),
          );
          expect(tester.takeException(), isNull, reason: l.label);
        }
      }
    });
  });
}
