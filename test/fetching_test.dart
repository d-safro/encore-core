import 'dart:math';

import 'package:encore/core/settings.dart';
import 'package:encore/data/models.dart';
import 'package:encore/data/subsonic.dart';
import 'package:encore/playback/autoplay.dart';
import 'package:encore/playback/fetching.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pretend music-lookup: answers with whatever [status] says for each song, and remembers what it was asked.
class FakeServer {
  final Map<String, (String, String?)> status = {};
  final List<List<String>> asked = [];
  Object? fail;

  Future<LookupReport> call(List<String> ids) async {
    asked.add(ids);
    if (fail != null) throw fail!;
    return LookupReport.fromJson({
      'song': [
        for (final id in ids)
          {'id': id, 'status': status[id]?.$1 ?? 'searching', 'songId': status[id]?.$2, 'temporary': true},
      ],
      'trialHours': 12,
      'perDay': 20,
    });
  }
}

void main() {
  group('songs you don\'t have, got automatically', () {
    late FakeServer server;
    late SongFetcher f;
    late DateTime now;
    final changes = <FetchInfo>[];
    var unreachable = 0;

    setUp(() {
      server = FakeServer();
      now = DateTime(2026, 11, 21, 12);
      changes.clear();
      unreachable = 0;
      f = SongFetcher(ask: server.call, clock: () => now)
        ..onChange = changes.add
        ..onUnreachable = () => unreachable++;
    });
    tearDown(() => f.reset());

    test('each song is asked for once; other ids are left alone', () async {
      await f.want(['dz-t-1', 'dz-t-1', 'song-9', 'dz-a-2']);
      await f.want(['dz-t-1']);
      expect(server.asked, [
        ['dz-t-1'],
      ]);
      expect(f['dz-t-1']?.status, FetchStatus.searching);
      expect(f.rules?.trialHours, 12);
    });

    test('tells each change once, and stops checking a song once it is there', () async {
      await f.want(['dz-t-1', 'dz-t-2']);
      server.status['dz-t-1'] = ('downloading', null);
      await f.check();
      server.status['dz-t-1'] = ('ready', 'nd-1');
      server.status['dz-t-2'] = ('notfound', null);
      await f.check();
      await f.check(); // nothing changed, nothing left to check
      expect(
        [for (final c in changes) '${c.id} ${c.status.name}'],
        ['dz-t-1 searching', 'dz-t-2 searching', 'dz-t-1 downloading', 'dz-t-1 ready', 'dz-t-2 notFound'],
      );
      expect(f['dz-t-1']?.songId, 'nd-1');
      expect(f['dz-t-1']?.temporary, isTrue);
      expect(f.watching, isEmpty);
      expect(server.asked.length, 3);
    });

    test('a song that takes too long is no longer checked (the server carries on)', () async {
      await f.want(['dz-t-1']);
      now = now.add(const Duration(minutes: 11));
      expect(f.watching, isEmpty);
    });

    test('the server extra missing says so once', () async {
      server.fail = SubsonicException(0, 'Server answered 404');
      await f.want(['dz-t-1']);
      await f.check();
      expect(unreachable, 1);
      expect(f.unreachable, isTrue);
      server.fail = null;
      await f.check();
      expect(f.unreachable, isFalse);
    });

    test('a server that keeps not answering counts as unreachable after three tries', () async {
      server.fail = Exception('timeout');
      await f.want(['dz-t-1']);
      await f.check();
      expect(unreachable, 0);
      await f.check();
      expect(unreachable, 1);
    });

    test('statuses from the server', () {
      final r = LookupReport.fromJson({
        'song': [
          {'id': 'dz-t-1', 'status': 'limit'},
          {'id': 'dz-t-2', 'status': 'ready', 'songId': 'x', 'temporary': true},
          {'id': 'dz-t-3', 'status': 'none'},
        ],
      });
      expect(r.songs.map((s) => s.status), [FetchStatus.limit, FetchStatus.ready, FetchStatus.none]);
      expect(r.songs[0].failed, isTrue);
      expect(r.songs[2].pending, isTrue);
      expect(r.trialHours, 24);
      expect(r.perDay, 40);
    });

    test('the rules in plain words', () {
      expect(trialRules(null), contains('deleted a day after they arrive'));
      expect(trialRules(null), contains('Up to 40 new songs a day'));
      expect(trialRules(const LookupReport(trialHours: 48, perDay: 10)), contains('deleted 48 hours after'));
      expect(trialRules(const LookupReport(trialHours: 1.5)), contains('1.5 hours'));
    });

    test('the setting is on unless switched off', () {
      expect(const Settings().autoGetSongs, isTrue);
      expect(Settings.fromJson({'autoGetSongs': false}).autoGetSongs, isFalse);
      expect(Settings.fromJson(const Settings().copyWith({'autoGetSongs': false}).toJson()).autoGetSongs, isFalse);
    });

    test('a song you don\'t have can show it\'s on its way', () {
      const s = Song(id: 'dz-t-1', title: 'X', lookup: LookupState.available);
      expect(s.copyWith(lookup: LookupState.downloading).lookup, LookupState.downloading);
      expect(s.copyWith(starred: true).lookup, LookupState.available);
    });

    test('autoplay may pick songs you don\'t have only when they\'re got automatically', () {
      final cands = [
        AutoCandidate(
          const Song(id: 'dz-t-1', title: 'New', artist: 'A', lookup: LookupState.available),
          AutoSource.soundAlike,
          0,
        ),
        AutoCandidate(const Song(id: 'b', title: 'Mine', artist: 'B'), AutoSource.soundAlike, 1),
      ];
      final off = pickAutoplay(candidates: cands, n: 5, rng: Random(1)).map((c) => c.song.id);
      final on = pickAutoplay(candidates: cands, n: 5, rng: Random(1), allowLookup: true).map((c) => c.song.id);
      expect(off, ['b']);
      expect(on.toSet(), {'dz-t-1', 'b'});
    });
  });
}
