import 'dart:convert';

import 'package:encore/data/follows.dart';
import 'package:encore/data/playlist_add.dart';
import 'package:encore/data/shows.dart';
import 'package:encore/ui/screens/following.dart' show niceDate;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('adding an album to a playlist', () {
    test('finds the songs already there, in album order', () {
      expect(alreadyIn(['a', 'c'], ['a', 'b', 'c']), ['a', 'c']);
      expect(alreadyIn([], ['a']), isEmpty);
    });

    test('skips duplicates only when asked, and keeps the order', () {
      expect(toSend(['b'], ['a', 'b', 'c'], skipDuplicates: true), ['a', 'c']);
      expect(toSend(['b'], ['a', 'b', 'c'], skipDuplicates: false), ['a', 'b', 'c']);
    });

    test('undo removes exactly the songs added at the end', () {
      expect(undoIndexes(['x', 'y', 'a', 'b'], 2, ['a', 'b']), [2, 3]);
    });

    test("undo refuses when the playlist changed since", () {
      expect(undoIndexes(['x', 'y', 'a', 'b', 'z'], 2, ['a', 'b']), isNull);
      expect(undoIndexes(['x', 'a', 'y', 'b'], 2, ['a', 'b']), isNull);
    });
  });

  const artist = FollowedArtist('ar1', 'The Band', mbid: 'mb-1');
  final now = DateTime(2026, 11, 21);

  group('new releases', () {
    final mb = {
      'release-groups': [
        {'title': 'New Album', 'first-release-date': '2026-12-05', 'primary-type': 'Album'},
        {'title': 'Last Single', 'first-release-date': '2026-10-01', 'primary-type': 'Single'},
        {'title': 'Live at Home', 'first-release-date': '2026-10-02', 'primary-type': 'Album', 'secondary-types': ['Live']},
        {'title': 'Best Of', 'first-release-date': '2026-09-02', 'primary-type': 'Album', 'secondary-types': ['Compilation']},
        {'title': 'Old Album', 'first-release-date': '2019-01-01', 'primary-type': 'Album'},
        {'title': 'A Video', 'first-release-date': '2026-11-01', 'primary-type': 'Other'},
      ],
    };

    test('MusicBrainz: studio releases in the window, not live albums or compilations', () {
      final l = parseMbReleases(mb, artist, now.subtract(releaseWindow));
      expect(l.map((r) => r.title), ['New Album', 'Last Single']);
      expect(l.first.upcoming(now), isTrue);
      expect(l.last.type, 'single');
    });

    test('Deezer fills the ⬇ link and adds what MusicBrainz lacks; your own copy wins', () {
      final mbl = parseMbReleases(mb, artist, now.subtract(releaseWindow));
      final dz = parseDeezerAlbums({
        'data': [
          {'id': 11, 'title': 'Last Single', 'release_date': '2026-10-01', 'record_type': 'single'},
          {'id': 12, 'title': 'Surprise EP', 'release_date': '2026-11-10', 'record_type': 'ep'},
          {'id': 13, 'title': 'Old Album', 'release_date': '2019-01-01', 'record_type': 'album'},
        ],
      }, now.subtract(releaseWindow));
      expect(dz.length, 2); // the old one is outside the window
      final merged = mergeReleases(artist, mbl, dz, {'surprise ep': 'own-7'});
      expect(merged.map((r) => r.title), ['New Album', 'Surprise EP', 'Last Single']); // newest first
      final single = merged.firstWhere((r) => r.title == 'Last Single');
      expect(single.route, '/album/dz-a-11');
      expect(merged.firstWhere((r) => r.title == 'Surprise EP').route, '/album/own-7');
      expect(merged.first.route, startsWith('/search?q='));
    });

    test("an artist's first check only takes note; later ones tell you what came out this week", () {
      final items = [
        const Release(artistId: 'ar1', artist: 'The Band', title: 'A', date: '2026-11-20'),
        const Release(artistId: 'ar1', artist: 'The Band', title: 'B', date: '2026-12-20'), // not out yet
        const Release(artistId: 'ar1', artist: 'The Band', title: 'C', date: '2026-08-01'), // too old to ring
      ];
      final seen = <String>{};
      expect(freshReleases(items, seen, firstCheck: true, now: now), isEmpty);
      expect(seen.length, 2);
      final seen2 = <String>{};
      expect(freshReleases(items, seen2, firstCheck: false, now: now).map((r) => r.title), ['A']);
      expect(freshReleases(items, seen2, firstCheck: false, now: now), isEmpty); // only once
    });

    test('asks MusicBrainz with the app\'s User-Agent, one request a second, and falls back to Deezer', () async {
      final times = <DateTime>[];
      final agents = <String?>[];
      final h = MockClient((req) async {
        if (req.url.host == 'musicbrainz.org') {
          times.add(DateTime.now());
          agents.add(req.headers['User-Agent']);
          if (req.url.path.endsWith('/artist')) {
            return http.Response(jsonEncode({'artists': [{'id': 'mb-9', 'name': 'The Band', 'score': 100}]}), 200);
          }
          return http.Response('busy', 503); // MusicBrainz is down: Deezer still answers
        }
        if (req.url.path == '/search/artist') {
          return http.Response(jsonEncode({'data': [{'id': 5, 'name': 'The Band'}]}), 200);
        }
        return http.Response(
          jsonEncode({'data': [{'id': 21, 'title': 'Fresh', 'release_date': '2026-11-15', 'record_type': 'album'}]}),
          200,
        );
      });
      final (l, mbid) = await fetchReleases(h, const FollowedArtist('ar1', 'The Band'), own: const {}, now: now);
      expect(mbid, 'mb-9');
      expect(l.single.dzId, '21');
      expect(agents.every((a) => a == mbUserAgent && !a!.contains('@')), isTrue);
      expect(times.length, 2);
      expect(times[1].difference(times[0]).inMilliseconds, greaterThanOrEqualTo(1000));
    });

    test('releases survive the cache', () {
      const r = Release(artistId: 'a', artist: 'B', title: 'C', date: '2026-01', type: 'ep', dzId: '4');
      final back = Release.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map);
      expect([back.key, back.date, back.type, back.dzId], [r.key, '2026-01', 'ep', '4']);
      expect(back.when, DateTime(2026, 1, 1));
    });
  });

  group('shows', () {
    test('Ticketmaster: only events where the artist really plays, upcoming, with place and tickets', () {
      final j = {
        '_embedded': {
          'events': [
            {
              'name': 'The Band: World Tour',
              'url': 'https://tm.example/e1',
              'dates': {'start': {'localDate': '2027-02-03', 'localTime': '20:00:00'}},
              '_embedded': {
                'attractions': [{'name': 'The Band'}],
                'venues': [
                  {'name': 'The Hall', 'city': {'name': 'Austin'}, 'state': {'name': 'Texas'}, 'country': {'name': 'United States Of America'}},
                ],
              },
            },
            {
              'name': 'The Band tribute night',
              'dates': {'start': {'localDate': '2027-02-04'}},
              '_embedded': {'attractions': [{'name': 'Tribute Act'}]},
            },
            {
              'name': 'Old show',
              'dates': {'start': {'localDate': '2020-02-04'}},
              '_embedded': {'attractions': [{'name': 'The Band'}]},
            },
          ],
        },
      };
      final l = parseTicketmaster(j, 'The Band', today: '2026-11-21');
      expect(l.length, 1);
      expect(l.single.time, '20:00');
      expect(l.single.place, 'The Hall, Austin, Texas, United States Of America');
      expect(l.single.url, 'https://tm.example/e1');
      expect(l.single.near('austin'), isTrue);
      expect(l.single.near('texas'), isTrue);
      expect(l.single.near('Berlin'), isFalse);
      expect(l.single.near(''), isTrue);
    });

    test('MusicBrainz events: future ones, with the venue, not cancelled', () {
      final j = {
        'events': [
          {
            'id': 'ev1',
            'name': 'Festival Day 1',
            'life-span': {'begin': '2027-06-01'},
            'relations': [
              {'place': {'name': 'Big Field'}},
              {'area': {'name': 'Leeds'}},
            ],
          },
          {'id': 'ev2', 'name': 'Gone', 'life-span': {'begin': '2001-06-01'}},
          {'id': 'ev3', 'name': 'Off', 'cancelled': true, 'life-span': {'begin': '2027-07-01'}},
        ],
      };
      final l = parseMbEvents(j, 'The Band', today: '2026-11-21');
      expect(l.single.venue, 'Big Field');
      expect(l.single.city, 'Leeds');
      expect(l.single.url, 'https://musicbrainz.org/event/ev1');
    });
  });

  test('dates read like people say them', () {
    final now = DateTime(2026, 11, 21); // a Saturday
    expect(niceDate('2026-11-21', now: now), 'Today');
    expect(niceDate('2026-11-22', now: now), 'Tomorrow');
    expect(niceDate('2026-11-25', now: now), 'Wed 25 Nov');
    expect(niceDate('2026-12-25', now: now), '25 Dec');
    expect(niceDate('2027-01-08', now: now), '8 Jan 2027');
    expect(niceDate('2027-03', now: now), 'Mar 2027');
  });
}
