import 'dart:convert';

import 'package:encore/core/settings.dart';
import 'package:encore/data/subsonic.dart';
import 'package:encore/playback/dj.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('a line, or none when the AI is off', () {
    final l = DjLine.fromJson({'id': '4c6e9cd5ad3aae0ab5b0', 'text': 'Here\'s Taxman.', 'duration': 5.69})!;
    expect(l.duration, 5.69);
    expect(DjLine.fromJson({'error': 'ai-off'}), isNull);
    expect(DjLine.fromJson({}), isNull);
  });

  test('asks the server about the songs either side, and where to hear it', () async {
    final asked = <Uri>[];
    final c = SubsonicClient(const Credentials('http://server', 'me', 'pw'), httpClient: MockClient((req) async {
      asked.add(req.url);
      return http.Response(jsonEncode({'subsonic-response': {'status': 'ok', 'djLine': {'id': 'abc', 'text': 'Hi', 'duration': 2}}}), 200);
    }));
    final l = await c.djLine(prev: 'a', next: 'b', lang: 'ru');
    expect(l!.id, 'abc');
    expect(asked.single.queryParameters['prev'], 'a');
    expect(asked.single.queryParameters['next'], 'b');
    expect(asked.single.queryParameters['lang'], 'ru');
    expect(c.djAudioUrl('abc').path, '/rest/djAudio');
    expect(c.djAudioUrl('abc').queryParameters['id'], 'abc');
    await c.djLine(next: 'b');
    expect(asked.last.queryParameters.containsKey('prev'), isFalse);
  });

  test('the language: picked, else the phone\'s, else English', () {
    expect(djLanguage('ru', 'de'), 'ru');
    expect(djLanguage('', 'de'), 'de');
    expect(djLanguage('', 'xx'), 'en');
  });

  test('off by default, every 3 songs', () {
    expect(const Settings().dj, isFalse);
    expect(const Settings().djEvery, 3);
    final s = Settings.fromJson(const Settings(dj: true, djEvery: 5).toJson());
    expect((s.dj, s.djEvery), (true, 5));
  });
}
