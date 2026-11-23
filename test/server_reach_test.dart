import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:encore_core/data/account.dart';
import 'package:encore_core/data/library.dart';
import 'package:encore_core/data/subsonic.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A server whose first [down] pings get no answer (a slow first connection), then answer.
(ProviderContainer, int Function()) _app(int down) {
  var pings = 0;
  final client = SubsonicClient(
    const Credentials('https://music.test', 'me', 'pw'),
    httpClient: MockClient((req) async {
      if (!req.url.path.endsWith('ping')) return http.Response('', 404);
      pings++;
      if (pings <= down) throw const SocketException('no answer yet');
      return http.Response(jsonEncode({'subsonic-response': {'status': 'ok'}}), 200);
    }),
  );
  final c = ProviderContainer(
    overrides: [
      clientProvider.overrideWithValue(client),
      connectivityProvider.overrideWith((ref) => Stream.value([ConnectivityResult.wifi])),
    ],
  );
  return (c, () => pings);
}

void main() {
  test('one ping with no answer at start (a slow first connection) does not make the app say offline', () {
    fakeAsync((t) {
      final (c, pings) = _app(1);
      final seen = <bool>[];
      c.listen<bool>(serverReachableProvider, (_, v) => seen.add(v), fireImmediately: true);
      t.flushMicrotasks();
      t.elapse(const Duration(seconds: 1));
      expect(c.read(serverReachableProvider), isTrue, reason: 'still optimistic after one miss');
      t.elapse(const Duration(seconds: 4)); // the quick second look answers
      expect(pings(), 2);
      expect(seen, everyElement(isTrue), reason: 'never shown offline');
      c.dispose();
    });
  });

  test('two pings in a row with no answer: offline, then back once the server answers', () {
    fakeAsync((t) {
      final (c, pings) = _app(2);
      c.listen<bool>(serverReachableProvider, (_, _) {}, fireImmediately: true);
      t.flushMicrotasks();
      t.elapse(const Duration(seconds: 5));
      expect(pings(), 2);
      expect(c.read(serverReachableProvider), isFalse);
      t.elapse(const Duration(seconds: 21)); // looks again every 20 s while offline
      expect(c.read(serverReachableProvider), isTrue);
      c.dispose();
    });
  });
}
