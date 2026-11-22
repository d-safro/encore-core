import 'dart:convert';

import 'package:encore_core/core/settings.dart';
import 'package:encore_core/data/account.dart';
import 'package:encore_core/data/lyrics_translation.dart';
import 'package:encore_core/data/subsonic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('reads the server answer and puts each line under its own', () {
    final t = LyricsTranslation.fromJson({
      'lang': 'en', 'source': 'es', 'same': false, 'lines': ['I love you', '', 'Oh oh'],
    });
    expect(t.source, 'es');
    expect(t.under(0, 'Te quiero'), 'I love you');
    expect(t.under(1, ''), isNull); // a break stays a break
    expect(t.under(2, 'Oh oh'), isNull); // unchanged: no second line
    expect(t.under(9, 'x'), isNull);
    expect(LyricsTranslation.fromJson({'error': 'ai-off'}).error, 'ai-off');
  });

  test('the language: picked, else the phone\'s, else English', () {
    expect(lyricsTargetLanguage('fr', 'de'), 'fr');
    expect(lyricsTargetLanguage('', 'de'), 'de');
    expect(lyricsTargetLanguage('', 'xx'), 'en');
  });

  test('romanize is offered for other alphabets only', () {
    expect(needsRomanizing(['愛してる', '君だけ', 'baby']), isTrue);
    expect(needsRomanizing(['Я тебя люблю']), isTrue);
    expect(needsRomanizing(['Te quiero', 'mi corazón', '', 'ok']), isFalse);
    expect(needsRomanizing(['', ' ']), isFalse);
  });

  group('a credit line in another script at the top', () {
    // made-up lyrics only
    const lines = [
      'Test Song - Test Band (测试乐队)',
      'First made-up line for you',
      '',
      'Second made-up line and the rest',
      'Third made-up line, now and then',
    ];

    test("doesn't count: the lyrics are English, nothing to translate into English", () {
      expect(lyricsAlreadyIn(lines, 'en', title: 'Test Song', artist: 'Test Band'), isTrue);
      expect(lyricsAlreadyIn(lines, 'en'), isTrue); // known from its shape alone, at the top
      expect(lyricsAlreadyIn(lines, 'fr'), isFalse); // still offered for another language
      expect(needsRomanizing(lines), isFalse);
    });

    test('is left out of what is sent, keeping every line in its place', () {
      final sent = linesToTranslate(lines, title: 'Test Song', artist: 'Test Band').split('\n');
      expect(sent.length, lines.length);
      expect(sent.first, '');
      expect(sent.skip(1), lines.skip(1));
    });

    test('lyrics mostly in another script still are', () {
      const other = ['Test Song - Test Band', '测试一', '测试二', '测试三', 'and one made-up line'];
      expect(lyricsAlreadyIn(other, 'en', title: 'Test Song'), isFalse);
      expect(lyricsAlreadyIn(other, 'zh', title: 'Test Song'), isTrue);
      expect(needsRomanizing(other, title: 'Test Song'), isTrue);
    });

    test('a sung line is not a credit', () {
      expect(isCreditLine('First made-up line for you'), isFalse);
      expect(isCreditLine('Written by Nobody Real'), isTrue);
      expect(isCreditLine('Made-up words - more words (aside)'), isFalse); // not the first line
      expect(isCreditLine('Made-up words - more words (aside)', first: true), isTrue);
    });
  });

  test('problems say what to do', () {
    expect(lyricsTranslationProblem('ai-off'), contains('Turn it on there'));
    expect(lyricsTranslationProblem('no-server'), contains('music-lookup'));
  });

  test('the language setting is saved', () {
    expect(Settings.fromJson(const Settings(lyricsLanguage: 'ja').toJson()).lyricsLanguage, 'ja');
  });

  test("a file on this device: its lyrics never go to the server", () async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final sent = <String>[];
    final client = SubsonicClient(const Credentials('http://server', 'me', 'pw'), httpClient: MockClient((req) async {
      if (req.url.path.endsWith('translateLyrics') || req.url.path.endsWith('translateLyrics.view')) sent.add(req.url.path);
      return http.Response(jsonEncode({'subsonic-response': {'status': 'ok', 'lyricsTranslation': {'lines': ['Hi']}}}), 200);
    }));
    final c = ProviderContainer(overrides: [clientProvider.overrideWithValue(client)]);
    addTearDown(c.dispose);
    final local = await c.read(lyricsTranslationProvider((id: 'lf-0123456789abcdef0123', romanize: false, text: 'Hola')).future);
    expect(local.error, 'private');
    expect(sent, isEmpty);
    expect(lyricsTranslationProblem('private'), contains('stay private'));
    final server = await c.read(lyricsTranslationProvider((id: 'mf-1', romanize: false, text: 'Hola')).future);
    expect(server.lines, ['Hi']); // the server's own songs still are
    expect(sent, hasLength(1));
  });
}
