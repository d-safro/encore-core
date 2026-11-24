// "Remove from library…" (Conductor's encore.removeSongs): what would go is asked first and shown file by file;
// nothing is removed until "I understand" is ticked and "Remove permanently" pressed; Cancel removes nothing; a user
// who isn't an admin is told so; removing sends exactly the files shown, with confirm=permanently.
import 'dart:convert';

import 'package:encore_core/core/appearance.dart';
import 'package:encore_core/core/settings.dart';
import 'package:encore_core/data/account.dart';
import 'package:encore_core/data/events.dart';
import 'package:encore_core/data/library.dart';
import 'package:encore_core/data/models.dart';
import 'package:encore_core/data/song_removal.dart';
import 'package:encore_core/data/subsonic.dart';
import 'package:encore_core/ui/actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

class FakeConductor {
  FakeConductor({this.admin = true});
  final bool admin;
  final asked = <Uri>[];

  List<Uri> calls(String method) => asked.where((u) => u.path.endsWith('/$method')).toList();

  http.Response _ok(Map<String, dynamic> body) =>
      http.Response(jsonEncode({'subsonic-response': {'status': 'ok', 'version': '1.16.1', ...body}}), 200);

  http.Client get client => MockClient((req) async {
    final u = req.method == 'POST' ? req.url.replace(query: req.body) : req.url;
    asked.add(u);
    switch (u.pathSegments.last) {
      case 'getOpenSubsonicExtensions':
        return _ok({
          'openSubsonicExtensions': [
            {'name': 'encore.removeSongs', 'versions': [1]},
          ],
        });
      case 'getSongRemoval' when !admin:
      case 'removeSongs' when !admin:
        return http.Response(
          jsonEncode({'subsonic-response': {'status': 'failed', 'error': {'code': 50, 'message': 'Only admins can remove songs'}}}),
          200,
        );
      case 'getSongRemoval':
        return _ok({
          'songRemoval': {
            'count': 2,
            'size': 3 * 1048576,
            'song': [
              {'id': 'tr-1', 'title': 'One', 'artist': 'Alpha', 'album': 'First', 'library': 'Music', 'path': 'Alpha/First/01 One.flac', 'size': 2 * 1048576},
              {'id': 'tr-9', 'title': 'One', 'artist': 'Alpha', 'album': 'Songs', 'library': 'Music', 'path': 'Songs/Alpha/Alpha - One.mp3', 'size': 1048576},
            ],
          },
        });
      case 'removeSongs':
        return _ok({
          'songsRemoved': {'removed': u.queryParametersAll['id'] ?? [], 'failed': []},
        });
    }
    return _ok({});
  });
}

/// This device's downloads, without files: remembers what it was told to drop.
class FakeDownloads extends DownloadsNotifier {
  static final dropped = <String>[];
  @override
  DownloadsState build() => const DownloadsState();
  @override
  Future<void> remove(Iterable<String> ids) async => dropped.addAll(ids);
}

SubsonicClient _client(FakeConductor s) =>
    SubsonicClient(const Credentials('http://conductor.test', 'me', 'pw'), httpClient: s.client);

const _song = Song(id: 'tr-1', title: 'One');

Widget _app(FakeConductor s) => ProviderScope(
  overrides: [
    clientProvider.overrideWithValue(_client(s)),
    liveEventsProvider.overrideWithValue(null),
    downloadsProvider.overrideWith(FakeDownloads.new),
  ],
  child: MaterialApp(
    theme: ThemeData(extensions: [AppLook.from(const Settings())]),
    home: Scaffold(
      body: Consumer(
        builder: (context, ref, _) =>
            TextButton(onPressed: () => removeSongForGood(context, ref, _song), child: const Text('remove')),
      ),
    ),
  ),
);

void main() {
  test('the calls: what would go, then exactly those, confirmed', () async {
    final s = FakeConductor();
    final c = _client(s);
    final what = await c.songRemoval(['tr-1']);
    expect(what.files.map((f) => f.path), ['Alpha/First/01 One.flac', 'Songs/Alpha/Alpha - One.mp3']);
    expect(what.size, 3 * 1048576);
    expect(await c.removeSongs(['tr-1', 'tr-9']), ['tr-1', 'tr-9']);
    final r = s.calls('removeSongs').single;
    expect(r.queryParametersAll['id'], ['tr-1', 'tr-9']);
    expect(r.queryParameters['confirm'], 'permanently');
  });

  testWidgets('nothing is removed until it is ticked and confirmed; Cancel removes nothing', (tester) async {
    final s = FakeConductor();
    await tester.pumpWidget(_app(s));
    await tester.tap(find.text('remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove "One" for good?'), findsOneWidget);
    expect(find.textContaining('all 2 copies'), findsOneWidget);
    expect(find.text('Music: Alpha/First/01 One.flac'), findsOneWidget);
    expect(find.text('Music: Songs/Alpha/Alpha - One.mp3'), findsOneWidget);
    // the button does nothing before "I understand" is ticked
    FilledButton button() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Remove permanently'));
    expect(button().onPressed, isNull);
    await tester.tap(find.text('Remove permanently'));
    await tester.pumpAndSettle();
    expect(s.calls('removeSongs'), isEmpty);
    // Cancel: nothing happens
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Remove "One" for good?'), findsNothing);
    expect(s.calls('removeSongs'), isEmpty);

    // again, ticked and confirmed: exactly the files shown
    await tester.tap(find.text('remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I understand it\'s deleted for good'));
    await tester.pump();
    expect(button().onPressed, isNotNull);
    await tester.tap(find.text('Remove permanently'));
    await tester.pumpAndSettle();
    final r = s.calls('removeSongs').single;
    expect(r.queryParametersAll['id'], ['tr-1', 'tr-9']);
    expect(r.queryParameters['confirm'], 'permanently');
    expect(find.text('Removed "One"'), findsOneWidget);
    expect(FakeDownloads.dropped, ['tr-1', 'tr-9'], reason: 'this device drops its downloads of them');
  });

  testWidgets('someone who isn\'t an admin is told so, and asked nothing', (tester) async {
    final s = FakeConductor(admin: false);
    await tester.pumpWidget(_app(s));
    await tester.tap(find.text('remove'));
    await tester.pumpAndSettle();
    expect(find.text('Only an admin of your server can remove songs'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(s.calls('removeSongs'), isEmpty);
  });

  test('offered only by a server with encore.removeSongs', () async {
    final s = FakeConductor();
    final ref = ProviderContainer(overrides: [clientProvider.overrideWithValue(_client(s))]);
    addTearDown(ref.dispose);
    expect(await ref.read(songRemovalOfferedProvider.future), isTrue);
  });
}
