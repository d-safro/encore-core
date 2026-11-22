import 'dart:convert';

import 'package:encore_core/data/scrobbling.dart';
import 'package:encore_core/data/subsonic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _ok(Map<String, dynamic> body) =>
    http.Response(jsonEncode({'subsonic-response': {'status': 'ok', ...body}}), 200);

void main() {
  test('reads what is linked', () {
    final s = Scrobbling.fromResponse({
      'scrobbling': {
        'listenbrainz': {'linked': true, 'name': 'me_lb', 'fromSettings': false, 'broken': false},
        'lastfm': {'available': false, 'linked': false, 'name': '', 'broken': false},
      },
    });
    expect((s.supported, s.listenBrainz.linked, s.listenBrainz.name), (true, true, 'me_lb'));
    expect((s.lastfm.available, s.lastfm.linked), (false, false));
  });

  test('the ListenBrainz token goes in the body, never in the address', () async {
    late http.Request seen;
    final c = SubsonicClient(const Credentials('http://server', 'me', 'pw'), httpClient: MockClient((req) async {
      seen = req;
      return _ok({
        'scrobbling': {
          'listenbrainz': {'linked': true, 'name': 'me_lb'},
          'lastfm': {'available': true},
        },
      });
    }));
    final s = await c.setListenBrainz('  secret-token ');
    expect(seen.method, 'POST');
    expect(seen.url.toString(), isNot(contains('secret-token')));
    expect(Uri.splitQueryString(seen.body)['token'], 'secret-token');
    expect(Uri.splitQueryString(seen.body)['f'], 'json');
    expect(s.listenBrainz.name, 'me_lb');
  });

  test('linking Last.fm: the approval page, then waiting until it is approved', () async {
    var approved = false;
    final c = SubsonicClient(const Credentials('http://server', 'me', 'pw'), httpClient: MockClient((req) async {
      final method = req.url.pathSegments.last.replaceAll('.view', '');
      return switch (method) {
        'lastfmLinkStart' => _ok({
          'lastfmLink': {'url': 'https://www.last.fm/api/auth/?api_key=k&token=t1', 'token': 't1'},
        }),
        'lastfmLinkFinish' => _ok({
          'lastfmLink': {'status': approved ? 'linked' : 'waiting', 'name': approved ? 'me_fm' : ''},
        }),
        _ => http.Response('', 404),
      };
    }));
    final link = await c.lastfmLinkStart();
    expect((link.url, link.token), ('https://www.last.fm/api/auth/?api_key=k&token=t1', 't1'));
    expect(await c.lastfmLinkFinish('t1'), 'waiting');
    approved = true;
    expect(await c.lastfmLinkFinish('t1'), 'linked');
  });

  test('a server without it (Navidrome, an older Conductor) says so: nothing is shown', () async {
    final c = SubsonicClient(const Credentials('http://server', 'me', 'pw'), httpClient: MockClient((req) async => http.Response('', 404)));
    expect(() => c.scrobbling(), throwsA(isA<SubsonicException>().having((e) => e.message, 'message', contains(' 404'))));
  });
}
