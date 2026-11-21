import 'dart:convert';

import 'package:encore/data/account.dart';
import 'package:encore/data/models.dart';
import 'package:encore/data/subsonic.dart';
import 'package:encore/ui/collab_sheet.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _p = Playlist(id: 'p1', name: 'Road trip', comment: '', owner: 'me', coverArt: '', songs: [
  Song(id: 's2', title: 'Two'),
]);

SubsonicClient client(Map<String, dynamic> share, List<String> asked) => SubsonicClient(
  const Credentials('http://server', 'me', 'pw'),
  httpClient: MockClient((req) async {
    asked.add(req.url.pathSegments.last);
    return http.Response(jsonEncode({'subsonic-response': {'status': 'ok', 'playlistShare': share}}), 200);
  }),
);

Widget app(SubsonicClient c) => ProviderScope(
  overrides: [clientProvider.overrideWithValue(c)],
  child: MaterialApp(
    home: Scaffold(body: Builder(builder: (ctx) => TextButton(onPressed: () => showInviteToEdit(ctx, _p), child: const Text('go')))),
  ),
);

void main() {
  test('reads the server answer', () {
    final s = PlaylistShare.fromJson({'url': 'https://x/jam/pl/t', 'added': [{'id': 's2', 'by': 'Ana'}]});
    expect(s.url, 'https://x/jam/pl/t');
    expect(s.added, [('s2', 'Ana')]);
  });

  testWidgets('shows the link and who added what', (tester) async {
    final asked = <String>[];
    await tester.pumpWidget(app(client({'url': 'https://x/jam/pl/t', 'added': [{'id': 's2', 'by': 'Ana'}]}, asked)));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(asked, ['playlistShareStart']);
    expect(find.text('https://x/jam/pl/t'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no public address: says so', (tester) async {
    await tester.pumpWidget(app(client({'url': ''}, [])));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.textContaining('JAM_PUBLIC_URL'), findsOneWidget);
  });
}
