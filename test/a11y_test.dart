import 'dart:io';

import 'package:encore/core/appearance.dart';
import 'package:encore/core/settings.dart';
import 'package:encore/data/models.dart';
import 'package:encore/ui/screens/appearance.dart';
import 'package:encore/ui/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('every icon button has a tooltip (what a screen reader says for it)', () {
    final missing = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final s = f.readAsStringSync();
      for (final m in RegExp(r'IconButton(\.filled|\.filledTonal|\.outlined)?\(').allMatches(s)) {
        var i = m.end, depth = 1;
        while (depth > 0 && i < s.length) {
          if (s[i] == '(') depth++;
          if (s[i] == ')') depth--;
          i++;
        }
        if (!s.substring(m.end, i).contains('tooltip:')) {
          missing.add('${f.path}:${'\n'.allMatches(s.substring(0, m.start)).length + 1}');
        }
      }
    }
    expect(missing, isEmpty);
  });

  test('a song row is read as one sentence', () {
    final s = Song.fromJson({'id': '1', 'title': 'Hey Jude', 'artist': 'The Beatles', 'duration': 431});
    expect(songSemanticsLabel(s), 'Hey Jude, The Beatles, 7:11');
    expect(
      songSemanticsLabel(s, current: true, downloaded: true, liked: true),
      'Hey Jude, The Beatles, 7:11, playing, downloaded, liked',
    );
    expect(songSemanticsLabel(s, available: false), endsWith('not available offline'));
  });

  testWidgets('animations stop when the phone or Appearance asks', (tester) async {
    late Duration on, off;
    await tester.pumpWidget(Builder(builder: (c) {
      on = motion(c, const Duration(milliseconds: 200));
      return const SizedBox();
    }));
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: Builder(builder: (c) {
        off = motion(c, const Duration(milliseconds: 200));
        return const SizedBox();
      }),
    ));
    expect(on, const Duration(milliseconds: 200));
    expect(off, Duration.zero);
  });

  test('Reduce animations is saved', () {
    final s = Settings.fromJson(const Settings(reduceMotion: true).toJson());
    expect(s.reduceMotion, isTrue);
    expect(const Settings().reduceMotion, isFalse);
  });

  testWidgets('Appearance meets the tap-target and label guidelines', (tester) async {
    final handle = tester.ensureSemantics();
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: ThemeData(extensions: [AppLook.from(c.read(settingsProvider))]),
        home: const AppearanceScreen(),
      ),
    ));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    final page = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
    await tester.scrollUntilVisible(find.text('Reduce animations'), 300, scrollable: page);
    await tester.tap(find.text('Reduce animations'));
    await tester.pump();
    expect(c.read(settingsProvider).reduceMotion, isTrue);
    handle.dispose();
  });
}
