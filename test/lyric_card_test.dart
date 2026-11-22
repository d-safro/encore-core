import 'package:encore/core/appearance.dart';
import 'package:encore/core/settings.dart';
import 'package:encore/data/models.dart';
import 'package:encore/ui/lyric_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _lines = [
  LyricLine(Duration(seconds: 1), 'The taxman\'s taken all my dough'),
  LyricLine(Duration(seconds: 4), ''),
  LyricLine(Duration(seconds: 6), 'And left me in my stately home'),
  LyricLine(Duration(seconds: 9), 'Lazing on a sunny afternoon, a very long line that has to wrap over several rows'),
  LyricLine(Duration(seconds: 12), 'And I can\'t sail my yacht'),
  LyricLine(Duration(seconds: 15), 'He\'s taken everything I\'ve got'),
];
const _song = Song(id: 's', title: 'Sunny Afternoon', artist: 'The Kinks');

void main() {
  test('the card\'s lines: from the one held, blank ones left out, at most four', () {
    expect(cardLines(_lines, 0, 2), ['The taxman\'s taken all my dough']); // the second is a break
    expect(cardLines(_lines, 2, 9).length, 4);
    expect(cardLines(_lines, 5, 3), ['He\'s taken everything I\'ve got']);
  });

  testWidgets('four long lines fit the card', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: ThemeData(extensions: [AppLook.from(const Settings())]),
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 320, height: 400, child: LyricCard(song: _song, lines: cardLines(_lines, 2, 4))),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.textContaining('stately home'), findsOneWidget);
    expect(find.text('Sunny Afternoon'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sheet grows and shrinks the card', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: ThemeData(extensions: [AppLook.from(const Settings())]),
        home: Scaffold(body: Builder(builder: (c) => TextButton(
          onPressed: () => showLyricCard(c, _song, _lines, 2), child: const Text('go')))),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('2 lines'), findsOneWidget);
    await tester.tap(find.byTooltip('One line more'));
    await tester.pump();
    expect(find.text('3 lines'), findsOneWidget);
    expect(find.textContaining('Lazing on a sunny'), findsOneWidget);
  });
}
