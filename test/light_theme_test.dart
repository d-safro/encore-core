import 'package:encore/app.dart';
import 'package:encore/core/appearance.dart';
import 'package:encore/core/settings.dart';
import 'package:encore/data/concerts.dart';
import 'package:encore/data/mixes.dart';
import 'package:encore/ui/screens/appearance.dart';
import 'package:encore/ui/screens/concerts.dart';
import 'package:encore/ui/screens/home.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _concerts = Concerts.fromJson({
  'city': 'Lisbon', 'source': 'MusicBrainz',
  'show': [{'artist': 'The Band', 'date': '2026-12-05', 'venue': 'Hall', 'city': 'Lisbon', 'url': 'https://x', 'first': 1}],
});
final _mixes = Mixes.fromJson({
  'kind': [], 'mix': [{'kind': 'daily', 'playlistId': 'p1', 'name': 'Daily Mix 1', 'comment': 'A, B and more'}],
});

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('the dark theme is the default, and the choice is kept', () {
    expect(const Settings().appTheme, AppTheme.dark);
    expect(Settings.fromJson({}).appTheme, AppTheme.dark);
    final light = const Settings().copyWith({'appTheme': 'light'});
    expect(light.appTheme, AppTheme.light);
    expect(Settings.fromJson(light.toJson()).appTheme, AppTheme.light);
    expect(Settings.fromJson({'appTheme': 'nonsense'}).appTheme, AppTheme.dark);
    expect(appearanceDefaults()['appTheme'], 'dark');
  });

  test('each theme has its own brightness, surfaces and text', () {
    const s = Settings();
    final dark = encoreTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4), brightness: Brightness.dark), s);
    final light = encoreTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)), s);
    expect(dark.brightness, Brightness.dark);
    expect(light.brightness, Brightness.light);
    expect(dark.colorScheme.surface.computeLuminance(), lessThan(0.05));
    expect(light.colorScheme.surface.computeLuminance(), greaterThan(0.85));
    expect(light.textTheme.bodyMedium!.color!.computeLuminance(), lessThan(0.1));
    // pure black is for the dark theme only
    final pure = const Settings().copyWith({'pureBlack': true});
    expect(encoreTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)), pure).colorScheme.surface,
        light.colorScheme.surface);
  });

  for (final brightness in Brightness.values) {
    Future<void> check(WidgetTester tester, Widget home) async {
      final handle = tester.ensureSemantics();
      const s = Settings();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          concertsProvider.overrideWith((ref) async => _concerts),
          mixesProvider.overrideWith((ref) async => _mixes),
        ],
        child: MaterialApp(
          theme: encoreTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4), brightness: brightness), s),
          home: MediaQuery(data: MediaQueryData.fromView(tester.view).copyWith(disableAnimations: true), child: home),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    }

    testWidgets('${brightness.name}: Appearance is readable', (t) => check(t, const AppearanceScreen()));
    testWidgets('${brightness.name}: Concerts are readable', (t) => check(t, const ConcertsScreen()));
    testWidgets('${brightness.name}: Your mixes row is readable',
        (t) => check(t, const Scaffold(body: SingleChildScrollView(child: MixesShelf()))));
  }
}
