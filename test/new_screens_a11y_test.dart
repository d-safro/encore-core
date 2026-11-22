import 'package:encore/core/appearance.dart';
import 'package:encore/core/platform.dart';
import 'package:encore/core/settings.dart';
import 'package:encore/data/concerts.dart';
import 'package:encore/data/mixes.dart';
import 'package:encore/data/review.dart';
import 'package:encore/ui/screens/concerts.dart';
import 'package:encore/ui/screens/home.dart';
import 'package:encore/ui/screens/review.dart';
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
final _review = ListeningReview.fromJson({
  'period': 'year', 'plays': 10, 'minutes': 100, 'songs': 5, 'artistCount': 2,
  'artist': [{'id': 'a', 'name': 'A', 'plays': 5, 'minutes': 50}],
  'song': [{'id': 's', 'title': 'S', 'artist': 'A', 'plays': 5}],
});

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> check(WidgetTester tester, Widget home) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        concertsProvider.overrideWith((ref) async => _concerts),
        mixesProvider.overrideWith((ref) async => _mixes),
        reviewProvider.overrideWith((ref, k) async => _review),
      ],
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, extensions: [AppLook.from(const Settings())]),
        home: MediaQuery(data: MediaQueryData.fromView(tester.view).copyWith(disableAnimations: true), child: home),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    // phones: 48 dp to touch (the desktop's mouse-sized page arrows are fine at 40)
    if (!isDesktop) await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  }

  testWidgets('Concerts', (t) => check(t, const ConcertsScreen()));
  testWidgets('Your mixes row', (t) => check(t, const Scaffold(body: SingleChildScrollView(child: MixesShelf()))));
  testWidgets('Concerts row', (t) => check(t, const Scaffold(body: SingleChildScrollView(child: ConcertsShelf()))));
  testWidgets('Year in review', (t) => check(t, const ReviewScreen()));
}
