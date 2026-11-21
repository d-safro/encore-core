import 'package:encore/core/appearance.dart';
import 'package:encore/core/settings.dart';
import 'package:encore/data/concerts.dart';
import 'package:encore/ui/screens/concerts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _json = {
  'city': 'Lisbon',
  'source': 'Ticketmaster',
  'updated': 1763700000000,
  'show': [
    {'artist': 'The Band', 'date': '2026-12-05', 'time': '20:30', 'name': 'Band live', 'venue': 'Hall',
     'city': 'Lisbon', 'country': 'Portugal', 'url': 'https://tm/1', 'source': 'Ticketmaster', 'first': 100},
    {'artist': 'Other', 'date': '2027-01-10', 'venue': 'Club', 'city': 'Lisbon', 'first': 500},
  ],
};

void main() {
  test('reads the server answer and finds the new ones', () {
    final c = Concerts.fromJson(_json);
    expect(c.city, 'Lisbon');
    expect(c.shows.length, 2);
    expect(newShows(c, 200).map((s) => s.artist), ['Other']);
  });

  test('dates and calendar entries', () {
    expect(showDate('2026-12-05', DateTime(2026, 11, 21)), 'Sat 5 Dec');
    expect(showDate('2027-01-10', DateTime(2026, 11, 21)), 'Sun 10 Jan 2027');
    final c = Concerts.fromJson(_json);
    expect(showStart(c.shows[0].$1), DateTime(2026, 12, 5, 20, 30));
    expect(showStart(c.shows[1].$1), DateTime(2027, 1, 10, 20)); // no time: 8 pm
    final ics = showIcs(c.shows[0].$1, stamp: DateTime.utc(2026, 11, 21));
    expect(ics, contains('DTSTART:20261205T203000'));
    expect(ics, contains('DTEND:20261205T233000'));
    expect(ics, contains('SUMMARY:The Band: Band live'));
    expect(ics, contains('LOCATION:Hall\\, Lisbon\\, Portugal'));
    expect(ics.split('\r\n').first, 'BEGIN:VCALENDAR');
  });

  Widget app(Widget child, Concerts c) => ProviderScope(
    overrides: [concertsProvider.overrideWith((ref) async => c)],
    child: MaterialApp(theme: ThemeData(extensions: [AppLook.from(const Settings())]), home: child),
  );

  testWidgets('the Home row and the list', (tester) async {
    final c = Concerts.fromJson(_json);
    await tester.pumpWidget(app(const Scaffold(body: SingleChildScrollView(child: ConcertsShelf())), c));
    await tester.pump();
    expect(find.text('Concerts near you'), findsOneWidget);
    expect(find.text('The Band'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(app(const ConcertsScreen(), c));
    await tester.pump();
    expect(find.text('Near Lisbon'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    await tester.tap(find.text('The Band'));
    await tester.pumpAndSettle();
    expect(find.text('Add to calendar'), findsOneWidget);
    expect(find.text('Tickets'), findsOneWidget);
  });

  testWidgets('nothing found: no Home row', (tester) async {
    await tester.pumpWidget(app(const Scaffold(body: ConcertsShelf()), const Concerts(city: 'x')));
    await tester.pump();
    expect(find.text('Concerts near you'), findsNothing);
  });
}
