import 'dart:convert';

import 'package:encore/core/settings.dart';
import 'package:encore/data/podcaster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test("a show's maker matches one of several names, not a longer one", () {
    expect(sameMaker('NPR', 'npr'), isTrue);
    expect(sameMaker('Ira Glass & WBEZ', 'Ira Glass'), isTrue);
    expect(sameMaker('Floyd, Simon and Chico', 'Simon'), isTrue);
    expect(sameMaker('Joe Rogan AI', 'Joe Rogan'), isFalse);
    expect(sameMaker('Anything', ''), isFalse);
    expect(makerNames('Tom Scott and David Bodycombe'), ['Tom Scott', 'David Bodycombe']);
    expect(makerNames('NPR'), ['NPR']);
  });

  test("the feed's website is the channel's link, not the cover's or atom's", () {
    const feed = '''<?xml version="1.0"?><rss><channel>
      <atom:link href="https://feeds.example.com/show.xml" rel="self"/>
      <title>Show</title>
      <image><url>https://cdn.example.com/c.jpg</url><link>https://cdn.example.com</link></image>
      <link><![CDATA[https://show.example.com/?a=1&amp;b=2]]></link>
      <item><link>https://show.example.com/ep1</link></item>''';
    expect(parseFeedWebsite(feed), 'https://show.example.com/?a=1&b=2');
    expect(parseFeedWebsite('<rss><channel><link>not a url</link>'), '');
  });

  test('looks up shows, the website and Wikipedia, keeps it, and fails quietly', () async {
    final seen = <String>[];
    Future<http.Response> handler(http.Request r) async {
      seen.add(r.url.host);
      if (r.url.host == 'itunes.apple.com') {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'artistName': 'Some Host',
                'collectionName': 'Show One',
                'feedUrl': 'https://f.example.com/1',
                'artworkUrl600': 'https://a.example.com/1.jpg',
                'artistViewUrl': 'https://podcasts.apple.com/us/artist/x/1?uo=4',
                'collectionViewUrl': 'https://podcasts.apple.com/us/podcast/one/2?uo=4',
                'trackCount': 12,
                'primaryGenreName': 'Comedy',
              },
              {'artistName': 'Some Host Fans', 'collectionName': 'Not theirs'},
              {'artistName': 'Some Host', 'collectionName': 'Show one'}, // the same show twice
            ],
          }),
          200,
        );
      }
      if (r.url.host == 'f.example.com') {
        return http.Response('<rss><channel><link>https://somehost.example</link><item>', 200);
      }
      if (r.url.host == 'en.wikipedia.org') {
        if (!r.url.path.endsWith('/Some_Host')) return http.Response('{}', 404);
        return http.Response(
          jsonEncode({
            'type': 'standard',
            'description': 'American podcaster',
            'extract': 'Some Host makes Show One.',
            'thumbnail': {'source': 'https://upload.wikimedia.org/p.jpg'},
            'content_urls': {
              'mobile': {'page': 'https://en.m.wikipedia.org/wiki/Some_Host'},
            },
          }),
          200,
        );
      }
      return http.Response('', 404);
    }

    final info = await http.runWithClient(
      () => fetchPodcaster('Some Host', feeds: ['https://f.example.com/1'], myShows: ['Show One']),
      () => MockClient(handler),
    );
    expect(info.shows.map((s) => s.title), ['Show One']);
    expect(info.shows.first.appleUrl, 'https://podcasts.apple.com/us/podcast/one/2');
    expect(info.appleUrl, 'https://podcasts.apple.com/us/artist/x/1');
    expect(info.website, 'https://somehost.example');
    expect(info.about, 'Some Host makes Show One.');
    expect(info.image, 'https://upload.wikimedia.org/p.jpg');
    expect(info.wikiUrl, 'https://en.m.wikipedia.org/wiki/Some_Host');
    expect(seen, containsAll(['itunes.apple.com', 'f.example.com', 'en.wikipedia.org']));

    // kept on the phone for offline use
    final (cached, fresh) = cachedPodcaster('some host');
    expect(fresh, isTrue);
    expect(cached?.website, 'https://somehost.example');
    expect(cached?.shows.single.episodes, 12);

    // nothing reachable: an empty answer, no error, and the phone's copy is left alone
    final none = await http.runWithClient(
      () => fetchPodcaster('Some Host', feeds: ['https://f.example.com/1']),
      () => MockClient((_) async => throw http.ClientException('offline')),
    );
    expect(none.isEmpty, isTrue);
    expect(cachedPodcaster('Some Host').$1?.about, 'Some Host makes Show One.');
  });

  test("other shows: Apple's maker id ties them to yours, else name-only and labelled unsure", () {
    const lateral = OnlineShow(title: 'Lateral', feedUrl: 'f1', artistId: '7');
    const sibling = OnlineShow(title: 'Another One', artistId: '7');
    const namesake = OnlineShow(title: 'Truu Review', episodes: 4);
    const titled = OnlineShow(title: 'A podcast by Tom Scott', episodes: 2);
    final sure = otherShows([lateral, sibling, namesake], 'Tom Scott', followedFeeds: {'f1'});
    expect(sure.sure, isTrue);
    expect(sure.shows.map((s) => s.title), ['Another One']);

    final unsure = otherShows([namesake, titled], 'Tom Scott');
    expect(unsure.sure, isFalse);
    expect(unsure.shows.map((s) => s.title), ['A podcast by Tom Scott', 'Truu Review']);

    // one maker id for every match: sure, even with none followed
    expect(otherShows([sibling, const OnlineShow(title: 'Third', artistId: '7')], 'NPR').sure, isTrue);
  });

  test('a Wikipedia article about someone else with the same name is skipped', () async {
    final info = await http.runWithClient(
      () => podcasterWiki('Jane Doe', ['Weekly Show']),
      () => MockClient(
        (r) async => http.Response(
          jsonEncode({'type': 'standard', 'description': 'American footballer', 'extract': 'Jane Doe plays football.'}),
          200,
        ),
      ),
    );
    expect(info.about, '');
  });
}
