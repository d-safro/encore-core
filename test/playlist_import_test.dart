import 'dart:convert';

import 'package:encore/data/models.dart';
import 'package:encore/data/subsonic.dart';
import 'package:encore/data/playlist_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Exportify CSV: quoted fields, commas, several artists', () {
    const csv = '"Track URI","Track Name","Artist Name(s)","Album Name"\n'
        '"spotify:track:1","Sunny Afternoon - Remastered","The Kinks","Face to Face"\n'
        '"spotify:track:2","Me, Myself and I","Beyoncé, Someone","Dangerously ""in"" Love"\n';
    final p = parsePlaylistFile('Road Trip.csv', csv).single;
    expect(p.name, 'Road Trip');
    expect(p.entries.map((e) => e.toString()).toList(), ['The Kinks - Sunny Afternoon - Remastered', 'Beyoncé - Me, Myself and I']);
    expect(p.entries.last.album, 'Dangerously "in" Love');
  });

  test('TuneMyMusic / Soundiiz headers; semicolon CSV', () {
    expect(parsePlaylistFile('a.csv', 'Track name,Artist name,Album\nHey Jude,The Beatles,1\n').single.entries.single.artist, 'The Beatles');
    expect(parsePlaylistFile('a.csv', 'title;artist;album\nTaxman;The Beatles;Revolver\n').single.entries.single.title, 'Taxman');
  });

  test('Spotify\'s own data download', () {
    final pl = jsonEncode({'playlists': [
      {'name': 'Mine', 'items': [{'track': {'trackName': 'Taxman', 'artistName': 'The Beatles', 'albumName': 'Revolver'}}]},
      {'name': 'Empty', 'items': []},
    ]});
    final out = parsePlaylistFile('Playlist1.json', pl);
    expect(out.map((p) => p.name).toList(), ['Mine', 'Empty']);
    expect(out.first.entries.single.album, 'Revolver');
    final lib = jsonEncode({'tracks': [{'artist': 'The Kinks', 'album': 'Face to Face', 'track': 'Sunny Afternoon'}]});
    expect(parsePlaylistFile('YourLibrary.json', lib).single.entries.single.title, 'Sunny Afternoon');
  });

  test('M3U and plain text', () {
    const m3u = '#EXTM3U\n#EXTINF:183,The Kinks - Sunny Afternoon\n/music/a.flac\n/music/The%20Beatles%20-%20Taxman.mp3\n';
    expect(parsePlaylistFile('x.m3u8', m3u).single.entries.map((e) => e.toString()).toList(), ['The Kinks - Sunny Afternoon', 'The Beatles - Taxman']);
    expect(parsePlaylistFile('x.txt', '1. The Kinks – Sunny Afternoon\n\nJust A Title\n').single.entries.map((e) => (e.artist, e.title)).toList(),
        [('The Kinks', 'Sunny Afternoon'), ('', 'Just A Title')]);
    expect(parsePlaylistFile('x.txt', '   '), isEmpty);
  });

  test('matching: the same song, yours before one to get, the versions ignored', () {
    expect(normTitle('Sunny Afternoon (Remastered 2004)'), normTitle('Sunny Afternoon'));
    expect(normTitle('Hey Jude - Remastered 2015'), 'heyjude');
    expect(normTitle('Song feat. Somebody'), 'song');
    const e = ImportEntry('Sunny Afternoon - Remastered', 'Kinks');
    final mine = const Song(id: 's1', title: 'Sunny Afternoon', artist: 'The Kinks');
    final toGet = const Song(id: 'dz-t-1', title: 'Sunny Afternoon', artist: 'The Kinks', lookup: LookupState.available);
    final other = const Song(id: 's2', title: 'Sunny Afternoon', artist: 'Someone Else');
    expect(bestMatch(e, [toGet, other, mine])?.id, 's1');
    expect(bestMatch(e, [toGet, other])?.id, 'dz-t-1');
    expect(bestMatch(e, [other]), isNull);
    expect(bestMatch(const ImportEntry('Sunny Afternoon', ''), [other])?.id, 's2'); // no artist known: the title
  });

  test('asks the server: yours, one to get (⬇ from music-lookup), or not found', () async {
    final asked = <String>[];
    final c = SubsonicClient(const Credentials('http://server', 'me', 'pw'), httpClient: MockClient((req) async {
      final q = req.url.queryParameters['query'] ?? '';
      asked.add(q);
      final songs = switch (q) {
        'The Kinks Sunny Afternoon' => [{'id': 's1', 'title': 'Sunny Afternoon', 'artist': 'The Kinks'}],
        'The Beatles Taxman' => [{'id': 'dz-t-9', 'title': '⬇ Taxman', 'artist': 'The Beatles'}],
        _ => <Map<String, Object>>[],
      };
      return http.Response.bytes(utf8.encode(jsonEncode({'subsonic-response': {'status': 'ok', 'searchResult3': {'song': songs}}})), 200);
    }));
    expect((await matchEntry(c, const ImportEntry('Sunny Afternoon', 'The Kinks')))?.id, 's1');
    final get = await matchEntry(c, const ImportEntry('Taxman', 'The Beatles'));
    expect((get?.id, get?.isLookup), ('dz-t-9', true));
    expect(await matchEntry(c, const ImportEntry('Nowhere', 'Nobody')), isNull);
    expect(asked.last, 'Nowhere'); // tried the title alone too
  });
}
