import 'dart:convert';

import 'package:encore/core/settings.dart';
import 'package:encore/data/audiobooks.dart';
import 'package:encore/data/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _a = AbsAccount('https://abs.example', 'tok', user: 'me');
const _id = 'li_8f2c-4a1b-9e77';

final _item = {
  'id': _id,
  'media': {
    'duration': 7200.0,
    'metadata': {'title': 'Dune', 'authorName': 'Frank Herbert', 'narratorName': 'Scott Brick'},
    'chapters': [
      {'start': 0, 'end': 1800, 'title': 'Book One'},
      {'start': 1800, 'end': 7200, 'title': 'Book Two'},
    ],
  },
};

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('a book with its chapters and your place', () {
    final b = Book.fromItem(_item, _a, progress: {'currentTime': 2000, 'progress': 0.28, 'isFinished': false});
    expect(b.title, 'Dune');
    expect(b.narrator, 'Scott Brick');
    expect(b.chapters.map((c) => c.title), ['Book One', 'Book Two']);
    expect(b.started, isTrue);
    expect(b.cover, 'https://abs.example/api/items/$_id/cover?token=tok');
    expect(bookLength(3900), '1 h 05 min');
    expect(bookLength(720), '12 min');
  });

  test('places in the book and in its files', () {
    const tracks = [BookTrack(0, 3600, 'u0', ''), BookTrack(3600, 3600, 'u1', '')];
    expect(trackAt(tracks, 4000), (1, 400.0));
    expect(trackAt(tracks, 10), (0, 10.0));
    expect(bookTime(tracks, 1, 400), 4000);
    final songs = bookSongs(Book.fromItem(_item, _a), tracks);
    expect(songs.map((s) => s.id), ['ab-$_id-0', 'ab-$_id-1']);
    expect(songs.every((s) => isPodcastId(s.id) && isAudiobookId(s.id)), isTrue); // spoken word: no scrobbles
    expect(isAudiobookId('pe-1'), isFalse);
  });

  test('a file\'s book, even when book ids have dashes', () {
    expect(bookIdOf('ab-$_id-3'), _id);
    expect(bookIdOf('pe-1'), isNull);
    expect(bookIdOf('ab-x'), isNull);
  });

  test('nothing to reopen when signed out', () async {
    await reopenBooks(['ab-$_id-0']); // no account kept: returns quietly
  });

  test('signs in, lists books, plays from where you were and keeps the place', () async {
    final sent = <String, Object?>{};
    final mock = MockClient((req) async {
      final p = req.url.path;
      if (req.method == 'POST') sent[p] = req.body.isEmpty ? null : jsonDecode(req.body);
      expect(p == '/login' || req.headers['Authorization'] == 'Bearer tok', isTrue);
      final body = switch (p) {
        '/login' => {'user': {'token': 'tok'}},
        '/api/me' => {'mediaProgress': [{'libraryItemId': _id, 'currentTime': 4000, 'progress': 0.55}]},
        '/api/libraries' => {'libraries': [{'id': 'lib1', 'mediaType': 'book'}, {'id': 'pods', 'mediaType': 'podcast'}]},
        '/api/libraries/lib1/items' => {'results': [_item]},
        '/api/items/$_id/play' => {
            'id': 'sess1',
            'currentTime': 4000,
            'audioTracks': [
              {'startOffset': 3600, 'duration': 3600, 'contentUrl': '/api/items/$_id/file/2'},
              {'startOffset': 0, 'duration': 3600, 'contentUrl': '/api/items/$_id/file/1'},
            ],
          },
        _ => <String, Object>{},
      };
      return http.Response(jsonEncode(body), 200);
    });
    final a = await absSignIn('abs.example/', 'me', 'pw', client: mock);
    expect(a.base, 'https://abs.example');
    final c = AbsClient(_a, client: mock);
    final books = await c.books();
    expect(books.single.position, 4000);
    final (session, tracks, at) = await c.play(_id);
    expect(session, 'sess1');
    expect(tracks.first.url, 'https://abs.example/api/items/$_id/file/1?token=tok'); // in order
    expect(at, 4000);
    await c.sync('sess1', 4100, 15, 7200);
    expect(sent['/api/session/sess1/sync'], {'currentTime': 4100, 'timeListened': 15, 'duration': 7200});
  });

  test('signing in adds the tab, signing out takes it away', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(absAccountProvider.notifier).signIn(_a);
    expect(c.read(settingsProvider).navTabs, contains('audiobooks'));
    expect(c.read(settingsProvider).navTabs.last, 'search');
    await c.read(absAccountProvider.notifier).signOut();
    expect(c.read(settingsProvider).navTabs, isNot(contains('audiobooks')));
    expect(c.read(absAccountProvider), isNull);
  });

  test("after a restart, opening the book again doesn't send your place back to the start", () async {
    final closed = <Object?>[];
    final mock = MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/close')) closed.add((jsonDecode(req.body) as Map)['currentTime']);
      final body = switch (p) {
        '/api/items/$_id/play' => {
            'id': 'sess1',
            'currentTime': 4000,
            'audioTracks': [{'startOffset': 0, 'duration': 7200, 'contentUrl': '/api/items/$_id/file/1'}],
          },
        '/api/items/$_id' => _item,
        _ => <String, Object>{},
      };
      return http.Response(jsonEncode(body), 200);
    });
    final was = absClientFor;
    absClientFor = (a) => AbsClient(a, client: mock);
    addTearDown(() => absClientFor = was);
    addTearDown(stopListening);
    FlutterSecureStorage.setMockInitialValues({'absServer': _a.base, 'absToken': _a.token});
    await reopenBooks(['ab-$_id-0']); // the queue the app came back with
    final b = Book.fromItem(_item, _a);
    await listen(_a, b, play: (songs, i, pos) async {}); // tapped on its page before playing the queue
    expect(closed, [4000]); // the reopened session closed where you were, not at 0
  });

  test('after a restart, a downloaded book in the queue plays from its files (no server needed)', () async {
    FlutterSecureStorage.setMockInitialValues({}); // signed out, or Audiobookshelf can't be reached
    await reopenBooks(['ab-kept-0', 'ab-kept-1'], local: {
      'kept': const [BookTrack(0, 600, '/books/kept/000.mp3', 'audio/mpeg'), BookTrack(600, 900, '/books/kept/001.mp3', 'audio/mpeg')],
    });
    expect(audiobookUrl('ab-kept-1'), Uri.file('/books/kept/001.mp3').toString());
    expect(audiobookMime('ab-kept-1'), 'audio/mpeg'); // what a speaker is told it gets, when casting
  });
}
