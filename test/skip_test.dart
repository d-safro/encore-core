// Skip back / forward by seconds: the setting, where a skip lands, the media session's buttons, and the player's
// buttons.
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:encore_core/core/settings.dart';
import 'package:encore_core/data/sync.dart';
import 'package:encore_core/playback/handler.dart';
import 'package:encore_core/playback/skip.dart';
import 'package:encore_core/ui/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Duration sec(int n) => Duration(seconds: n);

/// A player that only notes what it was asked to do.
class _Handler extends EncoreAudioHandler {
  _Handler(super.container);
  final asked = <String>[];
  final skips = <Duration>[];

  @override
  Future<void> seek(Duration position) async => asked.add('seek ${position.inSeconds}');
  @override
  Future<void> skipToNext() async => asked.add('next');
  @override
  Future<void> skipBy(Duration by) {
    skips.add(by);
    return super.skipBy(by);
  }

  /// Song [index] of [count], [length] long, at [at].
  void at(Duration at, {Duration length = const Duration(minutes: 3), int index = 0, int count = 2}) {
    queue.add([for (var i = 0; i < count; i++) MediaItem(id: 's$i', title: 'Song $i', duration: length)]);
    mediaItem.add(queue.value[index]);
    playbackState.add(PlaybackState(updatePosition: at, queueIndex: index, playing: false));
  }
}

/// Only what the buttons call (no player at all: widget tests run on pretend time).
class _Buttons implements EncoreAudioHandler {
  final skips = <Duration>[];
  @override
  Future<void> skipBy(Duration by) async => skips.add(by);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late ProviderContainer container;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    container = ProviderContainer();
  });
  tearDown(() => container.dispose());

  group('the setting', () {
    test('back 15 s and forward 30 s on everything at first', () {
      const d = Settings();
      expect((d.skipBack, d.skipForward, d.skipButtons), (15, 30, SkipButtons.everything));
    });

    test('is saved, and only the amounts on offer are taken', () {
      final saved = Settings.fromJson(jsonDecode(jsonEncode(
        const Settings(skipBack: 5, skipForward: 60, skipButtons: SkipButtons.spoken).toJson(),
      )) as Map<String, dynamic>);
      expect((saved.skipBack, saved.skipForward, saved.skipButtons), (5, 60, SkipButtons.spoken));
      final odd = Settings.fromJson({'skipBack': 7, 'skipForward': 'lots', 'skipButtons': 'nope'});
      expect((odd.skipBack, odd.skipForward, odd.skipButtons), (15, 30, SkipButtons.everything));
      expect(skipChoices, [5, 10, 15, 30, 60]);
    });

    test('is the same on all your devices (sync)', () {
      final v = syncedValues.singleWhere((v) => v.key == 'playerSkip');
      container.read(settingsProvider.notifier).update({'skipBack': 10, 'skipForward': 60, 'skipButtons': 'spoken'});
      final read = Provider((ref) => v.read(ref));
      expect(container.read(read), {'back': 10, 'forward': 60, 'for': 'spoken'});

      // another device's: taken; what it doesn't say stays
      final ref = container.read(Provider((ref) => ref));
      void write(Object? value) => v.write(ref, value);
      write({'back': 5, 'forward': 30, 'for': 'everything'});
      var st = container.read(settingsProvider);
      expect((st.skipBack, st.skipForward, st.skipButtons), (5, 30, SkipButtons.everything));
      write({'forward': 15});
      st = container.read(settingsProvider);
      expect((st.skipBack, st.skipForward), (5, 15));
      write('nonsense');
      expect(container.read(settingsProvider).skipBack, 5);
      // kept with the other settings too
      expect(Settings.fromJson(jsonDecode(prefs.getString('settings')!) as Map<String, dynamic>).skipForward, 15);
    });
  });

  group('where a skip lands', () {
    const len = Duration(minutes: 3);
    test('never before the start', () {
      expect(skipStep(sec(5), sec(-15), len, hasNext: true), const SkipSeek(Duration.zero));
      expect(skipStep(Duration.zero, sec(-15), len, hasNext: true), const SkipSeek(Duration.zero));
      expect(skipStep(sec(60), sec(-15), len, hasNext: true), SkipSeek(sec(45)));
    });

    test('past the end: the next song, or the very end of the last one', () {
      expect(skipStep(sec(60), sec(30), len, hasNext: true), SkipSeek(sec(90)));
      expect(skipStep(sec(170), sec(30), len, hasNext: true), const SkipNext());
      expect(skipStep(sec(150), sec(30), len, hasNext: true), const SkipNext()); // exactly the end
      expect(skipStep(sec(170), sec(30), len, hasNext: false), const SkipSeek(len));
    });

    test('a length not known yet: as far as asked', () {
      expect(skipStep(sec(60), sec(30), null, hasNext: true), SkipSeek(sec(90)));
      expect(skipStep(sec(60), sec(30), Duration.zero, hasNext: true), SkipSeek(sec(90)));
    });
  });

  group('the player', () {
    // its own player sends events of its own after a while: each skip is from the place set just before it
    Future<_Handler> handler() async {
      final h = _Handler(ProviderContainer()); // (left open: the player's late events still read the settings)
      return h;
    }

    test('rewind and fast-forward (notification, car, headphones, watch) use the setting', () async {
      final h = await handler();
      h.container.read(settingsProvider.notifier).update({'skipBack': 10, 'skipForward': 60});
      h.at(sec(100));
      await h.rewind();
      h.at(sec(100));
      await h.fastForward();
      expect(h.skips, [sec(-10), sec(60)]);
      expect(h.asked, ['seek 90', 'seek 160']);
    });

    test('clamps at the start, and goes on to the next song past the end', () async {
      final h = await handler();
      h.at(sec(4));
      await h.rewind();
      h.at(sec(170));
      await h.fastForward();
      h.at(sec(170), index: 1); // the last song: its very end
      await h.fastForward();
      expect(h.asked, ['seek 0', 'next', 'seek 180']);
    });
  });

  group('the media session\'s buttons', () {
    final usual = [
      MediaControl.skipToPrevious,
      MediaControl.pause,
      MediaControl.skipToNext,
      MediaControl.custom(androidIcon: 'drawable/ic_heart', label: 'Favourite', name: 'toggleStar'),
      MediaControl.custom(androidIcon: 'drawable/ic_aa_shuffle', label: 'Shuffle', name: 'cycleShuffle'),
    ];
    List<MediaAction> actions(List<MediaControl> c) => [for (final x in c) x.action];

    test('music: after heart and shuffle (those stay on the notification); compact view unchanged', () {
      final b = withSkipControls(usual, settings: const Settings(), id: 'song1');
      expect(actions(b.controls), [
        MediaAction.skipToPrevious,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.custom,
        MediaAction.custom,
        MediaAction.rewind,
        MediaAction.fastForward,
      ]);
      expect(b.compact, [0, 1, 2]);
      expect(b.controls[5].label, 'Back 15 seconds');
      expect(b.controls[6].label, 'Forward 30 seconds');
    });

    test('episodes and audiobooks: around previous / next, first among the custom buttons', () {
      for (final id in ['pe-1', 'ab-book-1']) {
        final b = withSkipControls(usual, settings: const Settings(skipForward: 10), id: id);
        expect(actions(b.controls).take(5), [
          MediaAction.rewind,
          MediaAction.skipToPrevious,
          MediaAction.pause,
          MediaAction.skipToNext,
          MediaAction.fastForward,
        ]);
        // previous, play and next in the compact view (it counts only the non-custom buttons)
        expect(b.compact, [1, 2, 3]);
        expect(b.controls[4].label, 'Forward 10 seconds');
      }
    });

    test('none for a radio station, or for music when only episodes and audiobooks get them', () {
      expect(withSkipControls(usual, settings: const Settings(), id: 'radio-abc').controls, usual);
      const spoken = Settings(skipButtons: SkipButtons.spoken);
      expect(withSkipControls(usual, settings: spoken, id: 'song1').controls, usual);
      expect(withSkipControls(usual, settings: spoken, id: 'pe-1').controls.length, 7);
      expect(withSkipControls(usual, settings: spoken, id: null).compact, [0, 1, 2]);
    });
  });

  group('the buttons', () {
    testWidgets('skip by the setting\'s seconds, with a label a screen reader says', (tester) async {
      final semantics = tester.ensureSemantics();
      container.read(settingsProvider.notifier).update({'skipBack': 5, 'skipForward': 60});
      container.read(settingsProvider.notifier).update({'skipBack': 5, 'skipForward': 60});
      final h = _Buttons();
      audioHandler = h;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: Row(children: [SkipButton(forward: false), SkipButton(forward: true, shortcut: 'Shift+→')])),
        ),
      ));
      expect(find.text('5'), findsOneWidget);
      expect(find.text('60'), findsOneWidget);
      expect(find.byTooltip('Back 5 seconds'), findsOneWidget);
      expect(find.byTooltip('Forward 60 seconds (Shift+→)'), findsOneWidget);
      // read as its tooltip, without the number drawn in the icon
      final node = tester.getSemantics(find.byType(IconButton).first);
      expect(node, containsSemantics(tooltip: 'Back 5 seconds', isButton: true));
      expect(node.label, isNot(contains('5')));
      await tester.tap(find.byType(SkipButton).first);
      await tester.tap(find.byType(SkipButton).last);
      expect(h.skips, [sec(-5), sec(60)]);
      // big enough to tap
      expect(tester.getSize(find.byType(IconButton).first).width, greaterThanOrEqualTo(48));
      semantics.dispose();
    });
  });
}
