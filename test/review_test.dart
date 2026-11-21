import 'package:encore/core/appearance.dart';
import 'package:encore/core/settings.dart';
import 'package:encore/data/review.dart';
import 'package:encore/ui/screens/review.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _json = {
  'period': 'year', 'plays': 1234, 'minutes': 5678, 'songs': 300, 'artistCount': 80, 'albumCount': 120,
  'newArtists': 12, 'hour': List.generate(24, (h) => h == 21 ? 90 : h),
  'song': [for (var i = 0; i < 5; i++) {'id': 's$i', 'title': 'Song $i', 'artist': 'Artist $i', 'plays': 50 - i}],
  'artist': [for (var i = 0; i < 5; i++) {'id': 'a$i', 'name': 'Artist $i', 'plays': 90 - i, 'minutes': 300}],
  'album': [for (var i = 0; i < 5; i++) {'id': 'al$i', 'name': 'Album $i', 'artist': 'Artist $i', 'plays': 40}],
  'genre': [{'name': 'Rock', 'minutes': 2000}, {'name': 'Jazz', 'minutes': 500}],
  'firstSong': {'id': 'f', 'title': 'Auld Lang Syne', 'artist': 'Someone'},
  'streak': {'days': 23, 'from': '2026-03-02'},
  'peakHour': 21,
  'discoveries': [{'id': 'd', 'title': 'New Love', 'artist': 'Newcomer', 'plays': 14}],
  'discoveryCount': 1,
};

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('reads the server answer', () {
    final r = ListeningReview.fromJson(_json);
    expect(r.stats.minutes, 5678);
    expect(r.stats.artists.first.$1.name, 'Artist 0');
    expect(r.genres.first, ('Rock', 2000));
    expect(r.firstSong?.title, 'Auld Lang Syne');
    expect(r.streakDays, 23);
    expect(r.streakFrom, DateTime(2026, 3, 2));
    expect(r.peakHour, 21);
    expect(r.discoveries.single.$2, 14);
    expect(ListeningReview.fromJson(const {'period': 'year'}).isEmpty, isTrue);
  });

  test('words', () {
    expect(hourLabel(0), 'midnight');
    expect(hourLabel(9), '9 am');
    expect(hourLabel(12), 'noon');
    expect(hourLabel(21), '9 pm');
    expect(thousands(5), '5');
    expect(thousands(1234567), '1,234,567');
    expect(reviewTitle('year', 1, DateTime(2026, 12, 1)), '2025');
    expect(reviewTitle('month', 1, DateTime(2026, 1, 15)), 'December 2025');
  });

  Future<void> pumpStory(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [reviewProvider.overrideWith((ref, k) async => ListeningReview.fromJson(_json))],
      child: MaterialApp(
        theme: ThemeData(extensions: [AppLook.from(const Settings())]),
        home: MediaQuery(
          data: MediaQueryData.fromView(tester.view).copyWith(disableAnimations: true), // tap through, no timer
          child: const ReviewScreen(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('every card draws on a phone, and taps move through them', (tester) async {
    await pumpStory(tester, const Size(390, 844));
    expect(find.text('5,678'), findsOneWidget);
    final seen = <String>[];
    for (var i = 0; i < 12; i++) {
      expect(tester.takeException(), isNull, reason: 'card $i');
      for (final k in ['Your top artist', 'Your top song', 'Your top album', 'Your top genre', 'It started with',
        'Your longest streak', 'Your hour', 'Found and kept']) {
        if (find.text(k).evaluate().isNotEmpty && !seen.contains(k)) seen.add(k);
      }
      await tester.tapAt(const Offset(350, 400)); // the right side: next
      await tester.pump();
    }
    expect(seen.length, 8);
    expect(find.text('Story'), findsOneWidget); // the share card at the end
    await tester.tap(find.text('Square'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(20, 400)); // the left side: back
    await tester.pump();
    expect(find.text('Found and kept'), findsOneWidget);
  });

  testWidgets('a share card fits a small desktop window', (tester) async {
    await pumpStory(tester, const Size(800, 600));
    for (var i = 0; i < 9; i++) {
      await tester.tapAt(const Offset(700, 300));
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });
}
