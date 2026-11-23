import 'dart:async';
import 'dart:convert';

import 'package:encore_core/data/devices.dart' show devicePollWait;
import 'package:encore_core/data/events.dart';
import 'package:encore_core/data/sync.dart' show syncShouldAsk, syncSafetyNet;
import 'package:flutter_test/flutter_test.dart';

/// A server's event stream, played by the test: each connect gets a new one, fed by hand.
class FakeServer {
  final streams = <StreamController<List<int>>>[];
  final asked = <String?>[]; // the Last-Event-ID of each connect
  final cancelled = <int>[];
  int failFirst = 0; // so many connects fail before one works

  Future<Stream<List<int>>> connect(String? last) async {
    asked.add(last);
    if (failFirst > 0) {
      failFirst--;
      throw Exception('offline');
    }
    final i = streams.length;
    final c = StreamController<List<int>>(onCancel: () => cancelled.add(i));
    streams.add(c);
    return c.stream;
  }

  void send(String text, [int? i]) => streams[i ?? streams.length - 1].add(utf8.encode(text));
  void hello(String id, {bool resumed = false}) =>
      send('retry: 5000\nid: $id\nevent: hello\ndata: {"keepalive":20,"resumed":$resumed,"events":[]}\n\n');
  Future<void> drop() => streams.last.close();
}

Future<void> until(bool Function() f, [String what = 'condition']) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!f()) {
    if (DateTime.now().isAfter(end)) fail('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('reading text/event-stream', () {
    Future<List<LiveEvent>> parse(List<String> chunks) =>
        parseEvents(Stream.fromIterable(chunks.map(utf8.encode))).toList();

    test('events, ids, keep-alives', () async {
      final got = await parse([
        'retry: 5000\nid: a-1\nevent: hello\ndata: {"resumed":false}\n\n',
        ': keep-alive\nid: a-3\n\n',
        'id: a-4\nevent: command\ndata: {"device":"x","seq":2}\n\n',
      ]);
      expect([for (final e in got) e.type], ['hello', '', 'command']);
      expect(got[0].data, {'resumed': false});
      expect(got[1].id, 'a-3'); // a keep-alive moves the id on
      expect(got[2].data['seq'], 2);
      expect(got[2].id, 'a-4');
    });

    test('split anywhere, CRLF, data over lines, no space after the colon', () async {
      final got = await parse(['event: sy', 'nc\r\ndata:{"key":\r\n', 'data: "pins"}\r\n', '\r\n', 'data: not json\n\n']);
      expect(got.length, 2);
      expect(got[0].type, 'sync');
      expect(got[0].data, {'key': 'pins'});
      expect(got[1].type, 'message');
      expect(got[1].data, isEmpty);
    });
  });

  group('keeping the stream open', () {
    late FakeServer server;
    late List<int> backoffs;
    LiveEvents live({Future<bool> Function()? offered, Duration quiet = const Duration(seconds: 50), Duration? pause}) {
      backoffs = [];
      return LiveEvents(
        server.connect,
        offered: offered,
        quietLimit: quiet,
        backoff: (n) {
          backoffs.add(n);
          return pause ?? const Duration(milliseconds: 10);
        },
      );
    }

    setUp(() => server = FakeServer());

    test('events come through, and it is healthy while a stream is open', () async {
      final l = live();
      final got = <LiveEvent>[];
      final health = <bool>[];
      l.events.listen(got.add);
      l.healthChanges.listen(health.add);
      l.start();
      await until(() => server.streams.length == 1);
      expect(l.healthy, false);
      server.hello('b-1');
      server.send(': keep-alive\n\n');
      server.send('id: b-2\nevent: devices\ndata: {"device":"phone"}\n\n');
      await until(() => got.isNotEmpty);
      expect(l.healthy, true);
      expect(got.single.type, 'devices'); // (hello and keep-alives aren't passed on)
      expect(l.lastEventId, 'b-2');
      await l.stop();
      expect(health, [true, false]);
      expect(server.cancelled, [0], reason: 'the connection is closed');
    });

    test('a dropped stream reconnects at once, resuming after the last event', () async {
      final l = live();
      final got = <String>[];
      l.events.listen((e) => got.add(e.type));
      l.start();
      await until(() => server.streams.length == 1);
      server.hello('b-1');
      server.send('id: b-7\nevent: sync\ndata: {"key":"pins"}\n\n');
      await until(() => got.isNotEmpty);
      await server.drop();
      await until(() => server.streams.length == 2);
      expect(server.asked, [null, 'b-7']);
      expect(backoffs, [0], reason: 'a stream that worked: the short pause');
      server.hello('b-7', resumed: true);
      await until(() => l.healthy);
      expect(got, ['sync'], reason: 'resumed: nothing to fetch anew');
      // the next gap can't be resumed (the server restarted): the app is told to fetch anew
      await server.drop();
      await until(() => server.streams.length == 3);
      server.hello('c-1');
      await until(() => got.length == 2);
      expect(got.last, 'resync');
      await l.stop();
    });

    test("can't connect: the pause grows; a quiet stream is taken for gone", () async {
      server.failFirst = 3;
      final l = live(quiet: const Duration(milliseconds: 200));
      l.start();
      await until(() => server.streams.length == 1);
      expect(backoffs, [1, 2, 3]);
      server.hello('b-1');
      await until(() => l.healthy);
      // no keep-alive comes: a new connection
      await until(() => server.streams.length == 2, 'reconnect after silence');
      expect(server.cancelled, contains(0));
      await l.stop();
      expect(LiveEvents.defaultBackoff(1).inSeconds, inInclusiveRange(1, 2));
      expect(LiveEvents.defaultBackoff(30).inSeconds, inInclusiveRange(60, 61));
    });

    test('back in front: tries at once instead of waiting out the pause', () async {
      server.failFirst = 1;
      final l = live(pause: const Duration(hours: 1));
      l.start();
      await until(() => server.asked.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.streams, isEmpty);
      l.retryNow();
      await until(() => server.streams.length == 1);
      await l.stop();
    });

    test('a server without encore.events: nothing is tried, the polls go on', () async {
      final l = live(offered: () async => false);
      l.start();
      await until(() => l.supported != null);
      expect(l.supported, false);
      expect(server.asked, isEmpty);
      expect(l.healthy, false);
      await l.stop();
      // the loops' fallbacks: long-polls and the half-minute sync, as before
      expect(devicePollWait(live: false), 20);
      expect(syncShouldAsk(live: false, changedHere: false, lastAsked: DateTime.now()), true);
    });
  });

  group('while the stream is up', () {
    test('devicePoll waits for an event, not on the server', () {
      expect(devicePollWait(live: true), 0);
    });

    test('sync asks the server only for a change here, or now and then', () {
      final now = DateTime(2026, 11, 23, 12);
      bool ask({bool changed = false, Duration ago = const Duration(minutes: 1)}) =>
          syncShouldAsk(live: true, changedHere: changed, lastAsked: now.subtract(ago), now: now);
      expect(ask(), false);
      expect(ask(changed: true), true);
      expect(ask(ago: syncSafetyNet), true);
      expect(syncShouldAsk(live: true, changedHere: false, lastAsked: null, now: now), true);
    });

    test('a loop waits until woken, or the safety net', () async {
      final w = LiveWake();
      w.wake();
      final t0 = DateTime.now();
      await w.wait(const Duration(seconds: 5)); // woken before: at once
      expect(DateTime.now().difference(t0).inMilliseconds, lessThan(500));
      unawaited(Future<void>.delayed(const Duration(milliseconds: 30), w.wake));
      await w.wait(const Duration(seconds: 5));
      expect(DateTime.now().difference(t0).inMilliseconds, lessThan(2000));
      await w.wait(const Duration(milliseconds: 30)); // nothing: the safety net
    });
  });
}
