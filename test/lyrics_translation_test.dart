import 'dart:convert';

import 'package:encore/core/settings.dart';
import 'package:encore/data/account.dart';
import 'package:encore/data/lyrics_translation.dart';
import 'package:encore/data/subsonic.dart';
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
