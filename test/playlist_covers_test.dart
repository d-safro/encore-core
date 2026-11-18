import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:encore/data/cover_crop.dart';
import 'package:encore/data/models.dart';
import 'package:encore/data/playlist_covers.dart';
import 'package:encore/data/subsonic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('which playlist picture shows', () {
    const sent = CustomCover(path: '/p/a.jpg', serverWas: 'pl-1_old', phoneOnly: false);
    const phone = CustomCover(path: '/p/b.jpg', serverWas: 'pl-1_old', phoneOnly: true);

    test('no picture of your own: the server\'s cover', () {
      expect(shownPlaylistCover(null, 'pl-1_old'), 'pl-1_old');
      expect(coverIsStale(null, 'pl-1_old'), isFalse);
    });

    test('sent to the server: the phone\'s copy until the server has a new cover id', () {
      expect(shownPlaylistCover(sent, 'pl-1_old'), 'file:/p/a.jpg');
      expect(coverIsStale(sent, 'pl-1_old'), isFalse);
      expect(shownPlaylistCover(sent, 'pl-1_new'), 'pl-1_new');
      expect(coverIsStale(sent, 'pl-1_new'), isTrue);
    });

    test('offline (no server cover id): the phone\'s copy, and it isn\'t thrown away', () {
      expect(shownPlaylistCover(sent, ''), 'file:/p/a.jpg');
      expect(coverIsStale(sent, ''), isFalse);
    });

    test('kept on the phone only: always the phone\'s copy', () {
      expect(shownPlaylistCover(phone, 'pl-1_new'), 'file:/p/b.jpg');
      expect(coverIsStale(phone, 'pl-1_new'), isFalse);
    });

    test('saved and read back; bad entries are skipped', () {
      final back = decodeCovers(encodeCovers({'1': sent, '2': phone}));
      expect(back['1']!.serverWas, 'pl-1_old');
      expect(back['1']!.phoneOnly, isFalse);
      expect(back['2']!.phoneOnly, isTrue);
      expect(decodeCovers(jsonEncode({'x': 'nonsense', '3': {'path': '/c.jpg'}})).keys, ['3']);
      expect(decodeCovers('not json'), isEmpty);
      expect(decodeCovers(null), isEmpty);
    });
  });

  test('album covers to pick from: one per album, in playlist order', () {
    const songs = [
      Song(id: '1', title: 'a', album: 'Red', albumId: 'r', coverArt: 'mf-1'),
      Song(id: '2', title: 'b', album: 'Red', albumId: 'r', coverArt: 'mf-2'),
      Song(id: '3', title: 'c', album: 'Blue', albumId: 'b', coverArt: 'mf-3'),
      Song(id: '4', title: 'd', album: 'None', albumId: 'n'),
    ];
    expect(albumCovers(songs), [('mf-1', 'Red'), ('mf-3', 'Blue')]);
  });

  group('square crop', () {
    test('starts centred, the short side filling the square', () {
      final c = SquareCrop.centred(const Size(2000, 1000), 300);
      expect(c.scale, closeTo(0.3, 1e-9));
      expect(c.source, const Rect.fromLTWH(500, 0, 1000, 1000));
      expect(c.outputSide, 1000);
    });

    test('dragging stops at the picture\'s edges', () {
      final c = SquareCrop.centred(const Size(2000, 1000), 300);
      expect(c.moved(const Offset(500, 500)).source.topLeft, Offset.zero);
      expect(c.moved(const Offset(-5000, -5000)).source.left, closeTo(1000, 1e-9));
    });

    test('pinching keeps the point under your fingers where it is', () {
      final from = SquareCrop.centred(const Size(1000, 1000), 300);
      final z = SquareCrop.pinch(from, const Offset(150, 150), const Offset(150, 150), 2);
      expect(z.zoom, 2);
      expect(z.source, const Rect.fromLTWH(250, 250, 500, 500));
      // a drag is a pinch at the same zoom
      final d = SquareCrop.pinch(z, const Offset(150, 150), const Offset(180, 150), 2);
      expect(d.source.left, closeTo(200, 1e-9));
      // zoom stays between 1 and the most
      expect(SquareCrop.pinch(from, Offset.zero, Offset.zero, 0.2).zoom, 1);
      expect(SquareCrop.pinch(from, Offset.zero, Offset.zero, 50).zoom, SquareCrop.maxZoom);
    });

    test('a small picture is saved at its own size, but at least 300 pixels', () {
      expect(SquareCrop.centred(const Size(600, 600), 300).outputSide, 600);
      expect(SquareCrop.centred(const Size(100, 100), 300).outputSide, 300);
    });

    test('pixels become a JPEG', () {
      final rgba = Uint8List(4 * 4 * 4)..fillRange(0, 64, 200);
      final jpeg = rgbaToJpeg((4, 4, rgba));
      expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
    });
  });

  group('playlist picture on the server', () {
    SubsonicClient client(Future<http.Response> Function(http.Request) handler) =>
        SubsonicClient(const Credentials('https://music.test', 'me', 'secret'), httpClient: MockClient(handler));

    test('signs in, then sends the picture as a form upload', () async {
      final seen = <String>[];
      final c = client((r) async {
        seen.add('${r.method} ${r.url.path}');
        if (r.url.path == '/auth/login') return http.Response(jsonEncode({'token': 'tok'}), 200);
        expect(r.headers['x-nd-authorization'], 'Bearer tok');
        expect(r.headers['content-type'], startsWith('multipart/form-data'));
        expect(latin1.decode(r.bodyBytes), contains('name="image"; filename="cover.jpg"'));
        return http.Response('{"status":"ok"}', 200);
      });
      await c.setPlaylistImage('abc', [0xFF, 0xD8, 1, 2]);
      expect(seen, ['POST /auth/login', 'POST /api/playlist/abc/image']);
    });

    test('signs in again when the token ran out', () async {
      var logins = 0, tries = 0;
      final c = client((r) async {
        if (r.url.path == '/auth/login') return http.Response(jsonEncode({'token': 't${++logins}'}), 200);
        tries++;
        return r.headers['x-nd-authorization'] == 'Bearer t2'
            ? http.Response('{"status":"ok"}', 200)
            : http.Response('', 401);
      });
      await c.removePlaylistImage('abc');
      expect((logins, tries), (2, 2));
    });

    test('uploads turned off, or a server without them: CoverRefused (kept on the phone instead)', () async {
      Future<void> answer(int code, String body) => client(
        (r) async => r.url.path == '/auth/login'
            ? http.Response(jsonEncode({'token': 'tok'}), 200)
            : http.Response(body, code),
      ).setPlaylistImage('abc', [1]);
      await expectLater(answer(403, 'artwork upload is disabled\n'), throwsA(isA<CoverRefused>()));
      await expectLater(answer(404, '404 page not found'), throwsA(isA<CoverRefused>()));
      await expectLater(answer(405, ''), throwsA(isA<CoverRefused>()));
      // someone else's playlist: a real error, not a reason to keep it on the phone
      await expectLater(
        answer(403, 'not authorized'),
        throwsA(isA<SubsonicException>().having((e) => e.code, 'code', 403)),
      );
      final notNavidrome = client((r) async => http.Response('', 404));
      await expectLater(notNavidrome.setPlaylistImage('abc', [1]), throwsA(isA<CoverRefused>()));
    });
  });
}
