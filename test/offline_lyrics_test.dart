import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encore/core/settings.dart';
import 'package:encore/data/embedded_lyrics.dart';
import 'package:encore/data/lyrics_translation.dart';
import 'package:encore/data/models.dart';
import 'package:encore/data/online_lyrics.dart';
import 'package:encore/data/saved_lyrics.dart';
import 'package:encore/data/song_lyrics.dart';
import 'package:encore/data/subsonic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const server = 'http://server';
const song = Song(id: 'mf-1', title: 'Sunny Afternoon', artist: 'The Kinks');

/// A server that answers getLyricsBySongId with [lines] (timed when [synced]); none when [lines] is null.
/// [asked] counts the lyrics questions; [down]: it can't be reached.
SubsonicClient fakeServer(List<String>? Function() lines, {bool synced = true, List<String>? asked, bool down = false}) =>
    SubsonicClient(
      const Credentials(server, 'me', 'pw'),
      httpClient: MockClient((req) async {
        final view = req.url.pathSegments.last.replaceAll('.view', '');
        if (view.startsWith('getLyrics')) asked?.add(view);
        if (down) throw http.ClientException('no route to host');
        final l = lines();
        final body = switch (view) {
          'getLyricsBySongId' => {
            'lyricsList': {
              'structuredLyrics': [
                if (l != null)
                  {
                    'synced': synced,
                    'line': [
                      for (final (i, t) in l.indexed) {if (synced) 'start': i * 1000, 'value': t},
                    ],
                  },
              ],
            },
          },
          _ => {'lyrics': {}},
        };
        return http.Response.bytes(utf8.encode(jsonEncode({'subsonic-response': {'status': 'ok', ...body}})), 200);
      }),
    );

void main() {
  late Directory tmp;
  late SavedLyrics store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tmp = await Directory.systemTemp.createTemp('lyrics');
    store = await SavedLyrics.open(Directory('${tmp.path}/lyrics'));
  });
  tearDown(() async => tmp.delete(recursive: true));

  LyricsAsk ask(SubsonicClient c, {bool online = true, bool keep = true, List<String> sources = const []}) =>
      LyricsAsk(server: server, client: c, online: online, keep: keep, store: store, sources: sources);

  group('the store', () {
    test('keeps timed and plain lyrics, per server, and reads them back', () async {
      final timed = Lyrics(
        synced: true,
        source: 'LRCLIB',
        lines: const [LyricLine(Duration(milliseconds: 1500), 'The tax man'), LyricLine(Duration(seconds: 4), '')],
      );
      await store.write(server, 'mf-1', SavedLyric(lyrics: timed, at: DateTime(2026, 11, 1), pick: 'lrclib|7'));
      await store.write(server, 'odd/id?', SavedLyric(lyrics: Lyrics.plain('one\ntwo'), at: DateTime(2026)));
      final back = (await store.read(server, 'mf-1'))!;
      expect(back.lyrics.synced, isTrue);
      expect(back.lyrics.source, 'LRCLIB');
      expect([for (final l in back.lyrics.lines) (l.start?.inMilliseconds, l.text)], [(1500, 'The tax man'), (4000, '')]);
      expect(back.pick, 'lrclib|7');
      expect(back.at, DateTime(2026, 11, 1));
      expect((await store.read(server, 'odd/id?'))!.lyrics.lines.map((l) => (l.start, l.text)), [(null, 'one'), (null, 'two')]);
      expect(SavedLyrics.fileName('odd/id?'), startsWith('h-')); // not a path
      expect(await store.read('http://another', 'mf-1'), isNull); // another server's songs are its own
      expect(await store.bytes(), greaterThan(0));
    });

    test('removing a download removes its lyrics; tidying keeps only the downloads', () async {
      for (final id in ['a', 'b', 'c']) {
        await store.write(server, id, SavedLyric(lyrics: Lyrics.plain(id), at: DateTime.now()));
      }
      await store.remove(server, ['a']);
      expect(await store.read(server, 'a'), isNull);
      expect(await store.keepOnly(server, {'b'}), 1);
      expect(await store.read(server, 'b'), isNotNull);
      expect(await store.read(server, 'c'), isNull);
    });

    test("Libretto's translations are kept only with lyrics that are kept", () async {
      const t = LyricsTranslation(lines: ['El recaudador'], source: 'en');
      final key = translationKey('es', false, 'The tax man');
      await store.addTranslation(server, 'mf-9', key, t); // not kept: nothing to add to
      expect(await store.read(server, 'mf-9'), isNull);
      await store.write(server, 'mf-1', SavedLyric(lyrics: Lyrics.plain('The tax man'), at: DateTime.now()));
      await store.addTranslation(server, 'mf-1', key, t);
      final back = (await store.read(server, 'mf-1'))!.translations[key]!;
      expect(back.lines, ['El recaudador']);
      expect(back.source, 'en');
      expect(translationKey('es', false, 'Other words'), isNot(key)); // other lyrics: not this translation
      expect(translationKey('es', true, 'The tax man'), isNot(key));
    });
  });

  group('the player', () {
    test('offline: the saved copy, and nothing asked', () async {
      final asked = <String>[];
      final c = fakeServer(() => ['new'], asked: asked);
      await store.write(server, song.id, SavedLyric(lyrics: Lyrics.plain('saved words'), at: DateTime(2020)));
      final l = await songLyrics(song, ask(c, online: false));
      expect(l.lines.single.text, 'saved words');
      expect(await songLyrics(const Song(id: 'mf-2', title: 'x'), ask(c, online: false)), isA<Lyrics>().having((l) => l.isEmpty, 'empty', true));
      expect(asked, isEmpty);
    });

    test('a downloaded song: looked up once, then answered from the saved copy', () async {
      final asked = <String>[];
      final c = fakeServer(() => ['line one', 'line two'], asked: asked);
      final first = await songLyrics(song, ask(c));
      expect(first.synced, isTrue);
      expect(asked, hasLength(1));
      final saved = (await store.read(server, song.id))!;
      expect(saved.lyrics.lines.map((l) => l.start!.inMilliseconds), [0, 1000]); // the times are kept
      await songLyrics(song, ask(c));
      expect(asked, hasLength(1));
    });

    test('a song that is not downloaded is not kept', () async {
      await songLyrics(song, ask(fakeServer(() => ['x']), keep: false));
      expect(await store.read(server, song.id), isNull);
    });

    test('an old saved copy answers at once and is refreshed in the background', () async {
      var words = ['old'];
      final c = fakeServer(() => words);
      final old = DateTime.now().subtract(SavedLyrics.foundAgain + const Duration(days: 1));
      await store.write(server, song.id, SavedLyric(lyrics: Lyrics.plain('old'), at: old));
      words = ['new words'];
      var changed = false;
      final l = await songLyrics(song, ask(c), changed: () => changed = true);
      expect(l.lines.single.text, 'old');
      for (var i = 0; i < 50 && !changed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(changed, isTrue);
      expect((await store.read(server, song.id))!.lyrics.lines.single.text, 'new words');
    });

    test('a new hand-picked choice is looked up again at once', () async {
      final asked = <String>[];
      final c = fakeServer(() => ['words'], asked: asked);
      await songLyrics(song, ask(c));
      pickLyrics(song.id, 'nowhere|1'); // a source that gives nothing: falls back to the server's
      await songLyrics(song, ask(c));
      expect(asked, hasLength(2));
      expect((await store.read(server, song.id))!.pick, 'nowhere|1');
    });
  });

  group('"no lyrics found"', () {
    test('is kept, so it is not asked on every play; asked again after a while', () async {
      final asked = <String>[];
      final c = fakeServer(() => null, asked: asked);
      expect((await songLyrics(song, ask(c))).isEmpty, isTrue);
      expect(asked, isNotEmpty);
      final n = asked.length;
      expect((await store.read(server, song.id))!.none, isTrue);
      await songLyrics(song, ask(c));
      expect(asked, hasLength(n));
      final later = DateTime.now().add(SavedLyrics.noneAgain + const Duration(days: 1));
      var changed = false;
      expect((await songLyrics(song, ask(c), now: later, changed: () => changed = true)).isEmpty, isTrue); // at once
      for (var i = 0; i < 50 && asked.length == n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(asked.length, greaterThan(n)); // and looked up again behind it
      expect(changed, isFalse); // still none

    });

    test('online sources switched on: asked again', () async {
      final asked = <String>[];
      final c = fakeServer(() => null, asked: asked);
      await songLyrics(song, ask(c));
      final n = asked.length;
      // 'none-such' is not a source: nothing goes on the internet, but the choice changed
      await songLyrics(song, ask(c, sources: ['none-such']));
      expect(asked.length, greaterThan(n));
    });

    test('is not kept when the server could not be reached', () async {
      final l = await songLyrics(song, ask(fakeServer(() => null, down: true)));
      expect(l.isEmpty, isTrue);
      expect(await store.read(server, song.id), isNull);
      const other = Song(id: 'mf-down', title: 'Lola', artist: 'The Kinks');
      expect(await keepLyrics(other, ask(fakeServer(() => null, down: true))), isNull); // the pass stops
      expect(await store.read(server, other.id), isNull);
    });

    test('never replaces lyrics found before', () async {
      final old = DateTime.now().subtract(SavedLyrics.foundAgain + const Duration(days: 1));
      await store.write(server, song.id, SavedLyric(lyrics: Lyrics.plain('kept'), at: old));
      expect(await keepLyrics(song, ask(fakeServer(() => null))), isTrue);
      final saved = (await store.read(server, song.id))!;
      expect(saved.lyrics.lines.single.text, 'kept');
      expect(saved.staleAt(DateTime.now()), isFalse); // checked: not asked again for a while
    });
  });

  group('downloads', () {
    test('fill in lyrics once', () async {
      final asked = <String>[];
      final c = fakeServer(() => ['a'], asked: asked);
      const s = Song(id: 'mf-fill', title: 'Taxman', artist: 'The Beatles');
      expect(await keepLyrics(s, ask(c)), isTrue);
      expect(await keepLyrics(s, ask(c)), isFalse);
      expect(asked, hasLength(1));
      expect(await keepLyrics(const Song(id: 'mf-other', title: 'x'), ask(c, online: false)), isFalse);
    });

    test('lyrics just shown are kept when the song is downloaded, without asking again', () async {
      final asked = <String>[];
      final c = fakeServer(() => ['shown'], asked: asked);
      const s = Song(id: 'mf-shown', title: 'Waterloo Sunset', artist: 'The Kinks');
      await songLyrics(s, ask(c, keep: false));
      expect(asked, hasLength(1));
      expect(await keepLyrics(s, ask(c)), isFalse);
      expect(asked, hasLength(1));
      expect((await store.read(server, s.id))!.lyrics.lines.single.text, 'shown');
    });
  });

  group('files on this device', () {
    Future<String> file(String name, List<int> bytes) async {
      final f = File('${tmp.path}/$name');
      await f.writeAsBytes(bytes);
      return f.path;
    }

    test('MP3: USLT (UTF-16) and SYLT (timed, a word at a time), timed first', () async {
      final path = await file('a.mp3', [
        ...id3(3, [frame3('USLT', [1, ...'eng'.codeUnits, ...utf16('') , 0, 0, ...utf16('Plain one\nPlain two')])]),
        ...List.filled(9000, 0xFF),
      ]);
      expect((await fileLyrics(path)).lines.map((l) => l.text), ['Plain one', 'Plain two']);
      final path4 = await file('b.mp3', [
        ...id3(4, [
          frame4('SYLT', [
            3, ...'eng'.codeUnits, 2, 1, 0, // UTF-8, ms, lyrics, no description
            ...piece('\nHello', 1000), ...piece(' there', 1500), ...piece('\nSecond', 3000),
          ]),
          frame4('USLT', [3, ...'eng'.codeUnits, 0, ...utf8.encode('Not timed')]),
        ]),
      ]);
      final l = await fileLyrics(path4);
      expect(l.synced, isTrue);
      expect([for (final x in l.lines) (x.start!.inMilliseconds, x.text)], [(1000, 'Hello there'), (3000, 'Second')]);
    });

    test('FLAC: UNSYNCEDLYRICS in its comments', () async {
      final path = await file('a.flac', [
        ...'fLaC'.codeUnits,
        0x00, 0, 0, 34, ...List.filled(34, 0), // STREAMINFO
        0x84, ...be3(comments(['TITLE=x', 'UNSYNCEDLYRICS=First\nSecond']).length),
        ...comments(['TITLE=x', 'UNSYNCEDLYRICS=First\nSecond']),
      ]);
      expect((await fileLyrics(path)).lines.map((l) => l.text), ['First', 'Second']);
    });

    test('Ogg Opus: LRC text in LYRICS is timed', () async {
      final tags = [...'OpusTags'.codeUnits, ...comments(['LYRICS=[00:01.00]One\n[00:02.50]Two'])];
      final path = await file('a.opus', [
        ...oggPage([...'OpusHead'.codeUnits, ...List.filled(11, 1)], 0),
        ...oggPage(tags, 1),
      ]);
      final l = await fileLyrics(path);
      expect(l.synced, isTrue);
      expect([for (final x in l.lines) (x.start!.inMilliseconds, x.text)], [(1000, 'One'), (2500, 'Two')]);
    });

    test('a .lrc beside the file, when its tags have none', () async {
      final path = await file('Song.mp3', [...id3(3, const []), ...List.filled(9000, 0xFF)]);
      await File('${tmp.path}/Song.lrc').writeAsString('[ar:Someone]\n[00:10.00]Ten\n[00:20.00]Twenty\n');
      final l = await fileLyrics(path);
      expect(l.synced, isTrue);
      expect(l.lines.map((x) => x.text), ['Ten', 'Twenty']);
      expect(l.source, 'the .lrc file');
    });

    test('a file with no lyrics, or not a music file at all', () async {
      expect((await fileLyrics(await file('n.mp3', [...id3(3, const []), 0, 0]))).isEmpty, isTrue);
      expect((await fileLyrics(await file('junk.ogg', utf8.encode('not music')))).isEmpty, isTrue);
      expect((await fileLyrics('${tmp.path}/missing.flac')).isEmpty, isTrue);
    });

    test('offline, a file on this device still shows (and keeps) its own lyrics', () async {
      final path = await file('Local.mp3', [...id3(3, const []), 0]);
      await File('${tmp.path}/Local.lrc').writeAsString('[00:01.00]Mine\n[00:02.00]Only\n');
      const local = Song(id: 'lf-123', title: 'Local');
      final a = LyricsAsk(server: SavedLyrics.localServer, localUri: path, keep: true, store: store);
      expect((await songLyrics(local, a)).lines.first.text, 'Mine');
      expect((await store.read(SavedLyrics.localServer, 'lf-123'))!.lyrics.synced, isTrue);
    });

    test('plain text or LRC', () {
      expect(lyricsFromText('[00:01.00]a\r\n[00:02.00]b').synced, isTrue);
      expect(lyricsFromText('just words\nmore').synced, isFalse);
      expect(lyricsFromText('  ').isEmpty, isTrue);
    });
  });
}

// ── Building test files ──
List<int> synchsafe(int n) => [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F];
List<int> be4(int n) => [(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];
List<int> be3(int n) => [(n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];
List<int> le4(int n) => [n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF];

List<int> id3(int ver, List<List<int>> frames) {
  final body = [for (final f in frames) ...f, ...List.filled(16, 0)]; // and some padding
  return [...'ID3'.codeUnits, ver, 0, 0, ...synchsafe(body.length), ...body];
}

List<int> frame3(String id, List<int> data) => [...id.codeUnits, ...be4(data.length), 0, 0, ...data];
List<int> frame4(String id, List<int> data) => [...id.codeUnits, ...synchsafe(data.length), 0, 0, ...data];

/// UTF-16 little-endian with its byte-order mark.
List<int> utf16(String s) => [0xFF, 0xFE, for (final u in s.codeUnits) ...[u & 0xFF, u >> 8]];

List<int> piece(String text, int ms) => [...utf8.encode(text), 0, ...be4(ms)];

List<int> comments(List<String> fields) => [
  ...le4(6), ...'Encore'.codeUnits, ...le4(fields.length),
  for (final f in fields) ...[...le4(utf8.encode(f).length), ...utf8.encode(f)],
];

List<int> oggPage(List<int> packet, int seq) {
  // segment lengths: as many 255s as fit, then the rest (0 when it fits exactly)
  final table = <int>[...List.filled(packet.length ~/ 255, 255), packet.length % 255];
  return Uint8List.fromList([
    ...'OggS'.codeUnits, 0, seq == 0 ? 2 : 0, ...List.filled(8, 0), ...le4(1), ...le4(seq), ...le4(0),
    table.length, ...table, ...packet,
  ]);
}
