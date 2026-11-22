import 'package:encore/core/settings.dart';
import 'package:encore/data/models.dart';
import 'package:encore/playback/transitions.dart';
import 'package:encore/ui/screens/transitions_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('chosen per pair, per playlist; unset follows Settings', () async {
    expect(transitionFor('p1', 'a', 'b'), isNull);
    await setTransition('p1', 'a', 'b', TransitionKind.cut);
    await setTransition('p1', 'b', 'c', TransitionKind.smart);
    expect(transitionFor('p1', 'a', 'b'), TransitionKind.cut);
    expect(transitionFor('p1', 'b', 'a'), isNull); // in that order only
    expect(transitionFor('p2', 'a', 'b'), isNull);
    expect(transitionFor(null, 'a', 'b'), isNull);
    expect(wantsSmart('p1'), isTrue);
    await setTransition('p1', 'b', 'c', null);
    await setTransition('p1', 'a', 'b', null);
    expect(prefs.getString('playlistTransitions'), '{}');
    expect(wantsSmart('p1'), isFalse);
  });

  testWidgets('the screen sets them', (tester) async {
    const p = Playlist(id: 'p1', name: 'Road trip', comment: '', owner: 'me', coverArt: '', songs: [
      Song(id: 'a', title: 'One'), Song(id: 'b', title: 'Two'), Song(id: 'c', title: 'Three'),
    ]);
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: TransitionsScreen(playlist: p))));
    expect(find.text('Cut'), findsNWidgets(2)); // between each song and the next
    await tester.tap(find.text('Cut').first);
    await tester.pumpAndSettle();
    expect(transitionFor('p1', 'a', 'b'), TransitionKind.cut);
    expect(transitionFor('p1', 'b', 'c'), isNull);
    expect(tester.takeException(), isNull);
  });
}
