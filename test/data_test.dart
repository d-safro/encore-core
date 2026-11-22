import 'dart:convert';

import 'package:encore/core/settings.dart';
import 'package:encore/data/library.dart';
import 'package:encore/data/models.dart';
import 'package:encore/data/subsonic.dart';
import 'package:encore/data/updates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> ok(Map<String, dynamic> body) => {
  'subsonic-response': {'status': 'ok', 'version': '1.16.1', ...body},
};

void main() {
  group('updates', () {
    test('versions compare by number, not text', () {
      expect(compareVersions('1.10.0', '1.9.9'), 1);
      expect(compareVersions('v1.6.0', '1.6.0'), 0);
      expect(compareVersions('1.6.0', '1.6.1'), -1);
      expect(compareVersions('2.0', '1.99.99'), 1);
      expect(compareVersions('1.7.0-beta', '1.7.0'), 0);
    });

    test("the APK for the phone's processor, else the universal one", () {
      final names = ['encore-1.7.0-arm64-v8a.apk', 'encore-1.7.0-armeabi-v7a.apk', 'encore-1.7.0-universal.apk'];
      expect(pickApk(names, ['arm64-v8a', 'armeabi-v7a']), 'encore-1.7.0-arm64-v8a.apk');
      expect(pickApk(names, ['x86_64']), 'encore-1.7.0-universal.apk');
      expect(pickApk(['notes.txt'], ['arm64-v8a']), isNull);
    });
  });

  group('download quality', () {
    test("levels match Spotify's names and High is the default", () {
      expect(downloadLevels.map((l) => l.$1), ['Low', 'Normal', 'High', 'Very high', 'Lossless']);
      const d = Settings();
      expect(downloadLevelOf(d.downloadFormat, d.downloadBitrate)?.$1, 'High');
      expect(downloadLevelOf('raw', 0)?.$1, 'Lossless');
      expect(downloadLevelOf('mp3', 192), isNull);
    });

    test('a 4-minute song at High is about 4.8 MB', () {
      final mb = DownloadsNotifier.sizeAt(const Song(id: 'x', title: 't', duration: 240), 160) / 1e6;
      expect(mb, closeTo(4.8, 0.01));
    });
  });

  group('models', () {
    test('albums keep "not in your library" when saved and read back', () {
      final a = Album.fromJson({'id': 'dz-1', 'name': '⬇ Something', 'artist': 'X'});
      expect(a.isLookup, isTrue);
      final back = Album.fromJson(a.toJson());
      expect(back.isLookup, isTrue);
      expect(back.name, 'Something');
    });

    test('playlists keep their change date', () {
      final p = Playlist.fromJson({'id': '1', 'name': 'P', 'changed': '2026-11-15T10:00:00Z'});
      expect(Playlist.fromJson(p.toJson()).changed, p.changed);
    });

    test('listening stats read the server answer', () {
      final s = ListeningStats.fromJson({
        'period': 'week',
        'plays': 3,
        'minutes': 12,
        'songs': 2,
        'artistCount': 1,
        'from': DateTime(2026, 11, 9).millisecondsSinceEpoch,
        'song': [
          {'id': 's1', 'title': 'A', 'plays': 2},
        ],
        'artist': [
          {'id': 'ar1', 'name': 'X', 'plays': 3, 'minutes': 12},
        ],
        'day': [
          {'date': '2026-11-10', 'minutes': 12},
        ],
        'hour': List.filled(24, 0),
      });
      expect(s.plays, 3);
      expect(s.songs.single.$2, 2);
      expect(s.artists.single.$1.name, 'X');
      expect(s.days.single.$1, DateTime(2026, 11, 10));
      expect(s.isEmpty, isFalse);
    });
  });

  group('server client', () {
    SubsonicClient client(Future<http.Response> Function(http.Request) handler) =>
        SubsonicClient(const Credentials('https://music.test', 'me', 'secret'), httpClient: MockClient(handler));

    test('stats and folders come back parsed', () async {
      final c = client((r) async {
        if (r.url.path.endsWith('getListeningStats')) {
          expect(r.url.queryParameters['period'], 'month');
          return http.Response(jsonEncode(ok({'listeningStats': {'period': 'month', 'plays': 5}})), 200);
        }
        if (r.url.path.endsWith('getFolder')) {
          return http.Response(
            jsonEncode(ok({
              'folder': {
                'dir': [
                  {'name': 'Albums', 'path': 'Albums', 'count': 3},
                ],
                'song': [
                  {'id': 'x', 'title': 'Loose'},
                ],
              },
            })),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      expect((await c.listeningStats('month')).plays, 5);
      final f = (await c.realFolder(''))!;
      expect(f.first.id, 'path:Albums');
      expect(f.last.song?.title, 'Loose');
    });

    test('a scrobble that fails can be ignored with catchError (no "wrong type" error)', () async {
      final c = client((r) async => http.Response('down', 502));
      // the player fires these and forgets them: the handler returns nothing
      await expectLater(c.scrobble('x', submission: false).catchError((_) {}), completes);
    });

    test('a folder request on a plain server gives null (the app falls back)', () async {
      final c = client((r) async => http.Response(jsonEncode(ok({})), 200));
      expect(await c.realFolder(''), isNull);
    });

    test("the server's reason a song won't stream", () async {
      final c = client((r) async {
        expect(r.headers['Range'], 'bytes=0-1023');
        return http.Response(
          jsonEncode({
            'subsonic-response': {
              'status': 'failed',
              'error': {'code': 0, 'message': 'open /music/x.mp3: input/output error'},
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      expect(await c.streamProblem('s'), contains('input/output error'));
      final fine = client((r) async => http.Response('ID3', 206, headers: {'content-type': 'audio/mpeg'}));
      expect(await fine.streamProblem('s'), isNull);
    });

    test('smart playlists sign in to Navidrome once, then create', () async {
      var logins = 0;
      final c = client((r) async {
        if (r.url.path == '/auth/login') {
          logins++;
          expect(jsonDecode(r.body), {'username': 'me', 'password': 'secret'});
          return http.Response(jsonEncode({'token': 'tok'}), 200);
        }
        if (r.url.path == '/api/playlist' && r.method == 'POST') {
          expect(r.headers['x-nd-authorization'], 'Bearer tok');
          final b = jsonDecode(r.body) as Map;
          expect(b['rules'], isA<Map>());
          return http.Response(jsonEncode({'id': 'pl1'}), 200);
        }
        if (r.url.path == '/api/playlist/pl1') {
          return http.Response(jsonEncode({'id': 'pl1', 'rules': {'all': []}}), 200);
        }
        if (r.url.path == '/api/playlist/plain') {
          return http.Response(jsonEncode({'id': 'plain', 'rules': null}), 200);
        }
        return http.Response('', 404);
      });
      expect(
        await c.createSmartPlaylist('Loved', {
          'all': [
            {'is': {'loved': true}},
          ],
        }),
        'pl1',
      );
      expect(await c.playlistRules('pl1'), {'all': []}); // smart, even with no rules yet
      expect(await c.playlistRules('plain'), isNull); // an ordinary playlist
      expect(logins, 1);
    });
  });
}
