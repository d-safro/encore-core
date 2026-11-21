import 'dart:async';
import 'dart:io';

import 'package:encore/data/library.dart' show coverIdsFor;
import 'package:encore/data/models.dart';
import 'package:encore/data/saved_covers.dart';
import 'package:flutter_test/flutter_test.dart';

const server = 'https://music.example';

/// A fake picture: different [seed]s give different bytes.
List<int> pic(int seed, [int len = 500]) => List.generate(len, (i) => (i * 7 + seed) % 251);

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('covers'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<List<String>> pictures() async => [
    for (final f in tmp.listSync())
      if (f.path.endsWith('.jpg')) f.path,
  ];

  test('the same picture under several covers is kept once', () async {
    final s = await SavedCovers.open(tmp);
    await s.save(server, 'mf-1', 600, pic(1));
    await s.save(server, 'mf-2', 600, pic(1)); // a song of the same album
    await s.save(server, 'al-1', 600, pic(1));
    await s.save(server, 'al-1', 200, pic(2));
    expect(await pictures(), hasLength(2));
    expect(s.file(server, 'mf-2', 600)!.path, s.file(server, 'al-1', 600)!.path);
    expect(s.file('https://other', 'mf-1', 600), isNull); // another server's covers are its own
  });

  test('the same picture arriving twice at once', () async {
    final s = await SavedCovers.open(tmp);
    await Future.wait([for (var i = 0; i < 8; i++) s.save(server, 'mf-$i', 600, pic(1))]);
    expect(await pictures(), hasLength(1));
    expect([for (var i = 0; i < 8; i++) s.file(server, 'mf-$i', 600)!.existsSync()], everyElement(isTrue));
  });

  test('the size that fits: small for lists, large for the player', () async {
    final s = await SavedCovers.open(tmp);
    await s.save(server, 'al-1', 200, pic(1));
    await s.save(server, 'al-1', 600, pic(2));
    expect(s.best(server, 'al-1', 200)!.$2, 200);
    expect(s.best(server, 'al-1', 500)!.$2, 600);
    expect(s.best(server, 'al-1', 1000)!.$2, 600);
    await s.save(server, 'al-2', 600, pic(3));
    expect(s.best(server, 'al-2', 100)!.$2, 600); // only the large one: that one
    expect(s.best(server, 'al-3', 100), isNull);
  });

  test('"no cover" is noted, not kept, and not asked for again', () async {
    final s = await SavedCovers.open(tmp);
    var asked = 0;
    await s.fill(server, ['ar-1'], (id, size) async {
      asked++;
      return const [0x7B, 0x22]; // an error message, not a picture
    });
    expect(asked, 2);
    expect(s.has(server, 'ar-1'), isTrue);
    expect(s.file(server, 'ar-1', 600), isNull);
    expect(await pictures(), isEmpty);
    await s.fill(server, ['ar-1'], (id, size) async => throw StateError('asked again'));
  });

  test('fill saves both sizes, skips what is there and survives a restart', () async {
    final s = await SavedCovers.open(tmp);
    final asked = <String>[];
    final n = await s.fill(server, ['al-1', 'al-2', 'al-1', ''], (id, size) async {
      asked.add('$id@$size');
      return pic(id.hashCode + size);
    });
    expect(n, 4);
    expect(asked..sort(), ['al-1@200', 'al-1@600', 'al-2@200', 'al-2@600']);
    final again = await SavedCovers.open(tmp);
    expect(again.has(server, 'al-1') && again.has(server, 'al-2'), isTrue);
    expect(await again.fill(server, ['al-1', 'al-2'], (id, size) async => throw StateError('asked again')), 0);
  });

  test('no server: fill stops, keeps what it saved, and says so', () async {
    final s = await SavedCovers.open(tmp);
    final ids = [for (var i = 0; i < 20; i++) 'al-$i'];
    var calls = 0;
    await expectLater(
      s.fill(server, ids, parallel: 1, (id, size) async {
        if (++calls > 3) throw const SocketException('no route to host');
        return pic(calls);
      }),
      throwsA(isA<SocketException>()),
    );
    expect(s.has(server, 'al-0'), isTrue);
    expect(s.has(server, 'al-5'), isFalse);
  });

  test('one slow picture is skipped for now, many in a row stop it', () async {
    final s = await SavedCovers.open(tmp);
    await s.fill(server, ['ar-slow', 'al-1'], parallel: 1, (id, size) async {
      if (id == 'ar-slow') throw TimeoutException('slow');
      return pic(size);
    });
    expect(s.has(server, 'al-1'), isTrue);
    expect(s.has(server, 'ar-slow'), isFalse); // tried again next time
    await expectLater(
      s.fill(
        server,
        [for (var i = 0; i < 10; i++) 'x-$i'],
        parallel: 1,
        (id, size) async => throw TimeoutException('x'),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('removed songs: their pictures go, shared ones and other servers stay', () async {
    final s = await SavedCovers.open(tmp);
    await s.save(server, 'mf-1', 600, pic(1));
    await s.save(server, 'al-1', 600, pic(1));
    await s.save(server, 'mf-9', 600, pic(9));
    await s.save('https://other', 'mf-9', 600, pic(8));
    expect(await s.keepOnly(server, {'al-1'}), 1); // pic(9) goes; pic(1) is still the album's
    expect(s.file(server, 'mf-1', 600), isNull);
    expect(s.file(server, 'al-1', 600)!.existsSync(), isTrue);
    expect(s.file('https://other', 'mf-9', 600)!.existsSync(), isTrue);
    expect(await pictures(), hasLength(2));
    expect(await s.bytes(), greaterThan(1000));
  });

  test('which covers a download keeps: song, album, artist and its playlists', () {
    const a = Song(id: 's1', title: 'A', coverArt: 'mf-1', albumId: 'al1', artistId: 'ar1');
    const b = Song(id: 's2', title: 'B', coverArt: 'mf-2', albumId: 'al1', artistId: 'ar2');
    final ids = coverIdsFor(
      [a, b],
      {'al1': 'al-1', 'al2': 'al-2'},
      {'ar1': 'ar-1'}, // ar2 isn't in the library copy
      {'p1': 'pl-1', 'p2': 'pl-2', 'p3': 'file:/mine.jpg'},
      {
        'p1': {'s9', 's2'},
        'p2': {'s9'},
        'p3': {'s1'},
      },
    );
    expect(ids, {'mf-1', 'mf-2', 'al-1', 'ar-1', 'pl-1'});
  });
}
