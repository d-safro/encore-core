import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:encore/playback/cast.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pretend Cast speaker: answers LAUNCH, LOAD, PAUSE, PLAY like Google's media receiver does.
class FakeSpeaker {
  late SecureServerSocket server;
  final got = <Map<String, dynamic>>[];

  Future<void> start(SecurityContext ctx) async {
    server = await SecureServerSocket.bind('127.0.0.1', 0, ctx);
    server.listen((sock) {
      var buf = Uint8List(0);
      sock.listen((data) {
        buf = Uint8List.fromList([...buf, ...data]);
        while (buf.length >= 4) {
          final len = ByteData.sublistView(buf, 0, 4).getUint32(0);
          if (buf.length < 4 + len) break;
          final (src, dst, ns, payload) = decodeCastMessage(Uint8List.sublistView(buf, 4, 4 + len));
          buf = Uint8List.fromList(buf.sublist(4 + len));
          final j = (jsonDecode(payload) as Map).cast<String, dynamic>();
          got.add({...j, '_ns': ns, '_dst': dst});
          void reply(String ns, Map<String, dynamic> p) =>
              sock.add(encodeCastMessage(dst, src, ns, jsonEncode({...p, 'requestId': j['requestId']})));
          switch (j['type']) {
            case 'LAUNCH':
              reply('urn:x-cast:com.google.cast.receiver', {
                'type': 'RECEIVER_STATUS',
                'status': {
                  'applications': [
                    {'appId': 'CC1AD845', 'transportId': 'web-7', 'sessionId': 'sess-1'},
                  ],
                  'volume': {'level': 0.4},
                },
              });
            case 'LOAD':
              reply('urn:x-cast:com.google.cast.media', {
                'type': 'MEDIA_STATUS',
                'status': [
                  {'mediaSessionId': 3, 'playerState': 'PLAYING', 'currentTime': j['currentTime']},
                ],
              });
            case 'PAUSE':
              reply('urn:x-cast:com.google.cast.media', {
                'type': 'MEDIA_STATUS',
                'status': [
                  {'mediaSessionId': 3, 'playerState': 'PAUSED', 'currentTime': 12.5},
                ],
              });
          }
        }
      }, onError: (_) {});
    });
  }
}

Future<SecurityContext?> _selfSigned(Directory dir) async {
  final key = '${dir.path}/key.pem', cert = '${dir.path}/cert.pem';
  try {
    final r = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', cert, '-days', '1',
      '-subj', '/CN=fake-speaker',
    ]);
    if (r.exitCode != 0) return null;
  } catch (_) {
    return null;
  }
  return SecurityContext()
    ..useCertificateChain(cert)
    ..usePrivateKey(key);
}

void main() {
  test('Cast messages survive encoding and decoding', () {
    final bytes = encodeCastMessage('sender-0', 'receiver-0', 'urn:x-cast:test', '{"type":"PING","ä":"ü"}');
    final len = ByteData.sublistView(bytes, 0, 4).getUint32(0);
    expect(len, bytes.length - 4);
    final (src, dst, ns, payload) = decodeCastMessage(Uint8List.sublistView(bytes, 4));
    expect(src, 'sender-0');
    expect(dst, 'receiver-0');
    expect(ns, 'urn:x-cast:test');
    expect(jsonDecode(payload), {'type': 'PING', 'ä': 'ü'});
  });

  test('long payloads use multi-byte lengths', () {
    final long = jsonEncode({'x': 'y' * 70000});
    final bytes = encodeCastMessage('a', 'b', 'c', long);
    final (_, _, _, payload) = decodeCastMessage(Uint8List.sublistView(bytes, 4));
    expect(payload, long);
  });

  test('a session launches the player, loads a song, follows pause', () async {
    final dir = await Directory.systemTemp.createTemp('cast');
    final ctx = await _selfSigned(dir);
    if (ctx == null) {
      markTestSkipped('openssl not available');
      return;
    }
    final speaker = FakeSpeaker();
    await speaker.start(ctx);
    final s = await CastSession.connect(CastDevice('Fake', '127.0.0.1', speaker.server.port));
    expect(s.volume, 0.4);
    final states = <String>[];
    final sub = s.status.stream.listen((st) => states.add(st.state));
    await s.load('http://phone/song', contentType: 'audio/flac', title: 'T', position: const Duration(seconds: 7));
    final load = speaker.got.firstWhere((m) => m['type'] == 'LOAD');
    expect(load['_dst'], 'web-7');
    expect(load['currentTime'], 7);
    expect((load['media'] as Map)['contentType'], 'audio/flac');
    s.pause();
    await Future.delayed(const Duration(milliseconds: 300));
    expect(states, containsAllInOrder(['PLAYING', 'PAUSED']));
    final pause = speaker.got.firstWhere((m) => m['type'] == 'PAUSE');
    expect(pause['mediaSessionId'], 3);
    await sub.cancel();
    await s.close();
    expect(speaker.got.any((m) => m['type'] == 'STOP' && m['sessionId'] == 'sess-1'), isTrue);
    await speaker.server.close();
    await dir.delete(recursive: true);
  });

  test('the relay serves a downloaded file with byte ranges, and nothing without its key', () async {
    final relay = (await CastRelay.start(host: '127.0.0.1'))!;
    final dir = await Directory.systemTemp.createTemp('relay');
    final f = File('${dir.path}/song.flac')..writeAsBytesSync(List.generate(1000, (i) => i % 256));
    final url = relay.songUrl('abc', f.path, 'audio/flac');
    final http = HttpClient();
    final req = await http.getUrl(Uri.parse(url))..headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
    final res = await req.close();
    expect(res.statusCode, HttpStatus.partialContent);
    expect(res.headers.value(HttpHeaders.contentRangeHeader), 'bytes 10-19/1000');
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(body, List.generate(10, (i) => 10 + i));
    final bad = await (await http.getUrl(Uri.parse(url.replaceFirst(RegExp(r'/[0-9a-f]{16}/'), '/0000000000000000/')))).close();
    expect(bad.statusCode, HttpStatus.notFound);
    await bad.drain<void>();
    http.close();
    await relay.stop();
    await dir.delete(recursive: true);
  });
}
