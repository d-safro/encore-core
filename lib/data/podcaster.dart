import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/settings.dart';
import 'artist_extra.dart' show normName;

/// What we can find out about whoever makes a podcast (a person, a network, or the show itself), for the
/// podcaster page. From three places, all public:
/// - the show's own RSS feed: its website (only the top of the feed is read);
/// - Apple's podcast directory: their other shows, searched by the exact author name;
/// - Wikipedia: a short summary and a picture, only when the article is clearly about a podcast or media maker.
/// Only names and the feed address are sent. The answer is kept on the phone, so the page works offline.
class PodcasterInfo {
  const PodcasterInfo({
    this.about = '',
    this.wikiUrl = '',
    this.image = '',
    this.website = '',
    this.appleUrl = '',
    this.shows = const [],
  });
  final String about, wikiUrl, image, website, appleUrl;
  final List<OnlineShow> shows;

  bool get isEmpty => about.isEmpty && image.isEmpty && website.isEmpty && appleUrl.isEmpty && shows.isEmpty;

  Map<String, dynamic> toJson() => {
    'about': about,
    'wikiUrl': wikiUrl,
    'image': image,
    'website': website,
    'appleUrl': appleUrl,
    'shows': [for (final s in shows) s.toJson()],
  };

  factory PodcasterInfo.fromJson(Map<String, dynamic> j) => PodcasterInfo(
    about: '${j['about'] ?? ''}',
    wikiUrl: '${j['wikiUrl'] ?? ''}',
    image: '${j['image'] ?? ''}',
    website: '${j['website'] ?? ''}',
    appleUrl: '${j['appleUrl'] ?? ''}',
    shows: [
      for (final s in (j['shows'] as List?) ?? const [])
        if (s is Map) OnlineShow.fromJson(s.cast<String, dynamic>()),
    ],
  );
}

/// A show from Apple's directory.
class OnlineShow {
  const OnlineShow({
    required this.title,
    this.author = '',
    this.feedUrl = '',
    this.artwork = '',
    this.genre = '',
    this.episodes,
    this.appleUrl = '',
    this.artistId = '',
  });
  final String title, author, feedUrl, artwork, genre, appleUrl;

  /// Apple's id for whoever makes it (only for some): shows with the same one are surely by the same maker.
  final String artistId;
  final int? episodes;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'feedUrl': feedUrl,
    'artwork': artwork,
    'genre': genre,
    'episodes': episodes,
    'appleUrl': appleUrl,
    'artistId': artistId,
  };

  factory OnlineShow.fromJson(Map<String, dynamic> j) => OnlineShow(
    title: '${j['title'] ?? ''}',
    author: '${j['author'] ?? ''}',
    feedUrl: '${j['feedUrl'] ?? ''}',
    artwork: '${j['artwork'] ?? ''}',
    genre: '${j['genre'] ?? ''}',
    episodes: (j['episodes'] as num?)?.toInt(),
    appleUrl: '${j['appleUrl'] ?? ''}',
    artistId: '${j['artistId'] ?? ''}',
  );
}

/// Their shows you don't follow yet. Apple's search goes by name only, so when Apple's own maker id ties them to
/// a show you follow (or all of them share one id) only those are kept and [sure] is true; otherwise these are
/// shows by anyone with that name: the ones naming them in the title first, then the bigger ones, at most 8.
({List<OnlineShow> shows, bool sure}) otherShows(
  List<OnlineShow> all,
  String name, {
  Set<String> followedFeeds = const {},
  Set<String> followedTitles = const {},
}) {
  bool followed(OnlineShow s) => followedFeeds.contains(s.feedUrl) || followedTitles.contains(normName(s.title));
  final ids = {for (final s in all) s.artistId};
  final mineIds = {
    for (final s in all)
      if (followed(s) && s.artistId.isNotEmpty) s.artistId,
  };
  final sureIds = mineIds.isNotEmpty ? mineIds : (ids.length == 1 && ids.first.isNotEmpty ? ids : const <String>{});
  final rest = all.where((s) => !followed(s)).toList();
  if (sureIds.isNotEmpty) return (shows: rest.where((s) => sureIds.contains(s.artistId)).toList(), sure: true);
  final n = normName(name);
  int score(OnlineShow s) =>
      (normName(s.title).contains(n) ? 1 << 20 : 0) +
      (s.artistId.isNotEmpty ? 1 << 19 : 0) +
      (s.episodes ?? 0).clamp(0, 1 << 18);
  rest.sort((a, b) => score(b).compareTo(score(a)));
  return (shows: rest.take(8).toList(), sure: false);
}

const _ua = {'User-Agent': 'Encore music player (https://github.com/d-safro/encore)'};

Future<dynamic> _getJson(Uri u) async {
  final r = await http.get(u, headers: _ua).timeout(const Duration(seconds: 10));
  if (r.statusCode != 200) return null;
  return jsonDecode(utf8.decode(r.bodyBytes));
}

/// True when [author] is [name], or one of several names in it ("Ira Glass & WBEZ" has "Ira Glass").
bool sameMaker(String author, String name) {
  final n = normName(name);
  if (n.isEmpty) return false;
  if (normName(author) == n) return true;
  return makerNames(author).any((p) => normName(p) == n);
}

/// The separate names in an author line: "Tom Scott and David Bodycombe" → Tom Scott, David Bodycombe.
List<String> makerNames(String author) => [
  for (final p in author.split(RegExp(r'\s*(?:,|&|\+|/|\band\b|\bwith\b)\s*', caseSensitive: false)))
    if (p.trim().isNotEmpty) p.trim(),
];

// ── The top of the RSS feed ──

String _unescape(String s) => s
    .replaceAll(RegExp(r'^<!\[CDATA\[|\]\]>$'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .trim();

/// The show's website, from the feed's channel part (everything before the first episode).
/// Only up to 256 KB is read: some feeds are tens of MB.
Future<String> feedWebsite(String feedUrl) async {
  const none = '';
  final u = Uri.tryParse(feedUrl);
  if (u == null || !u.scheme.startsWith('http')) return none;
  final client = http.Client();
  try {
    final req = http.Request('GET', u)..headers.addAll(_ua);
    final res = await client.send(req).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return none;
    final bytes = <int>[];
    await for (final chunk in res.stream.timeout(const Duration(seconds: 10))) {
      bytes.addAll(chunk);
      if (bytes.length > 256 * 1024) break;
      final tail = utf8.decode(bytes, allowMalformed: true);
      if (tail.contains('<item')) break;
    }
    return parseFeedWebsite(utf8.decode(bytes, allowMalformed: true));
  } catch (_) {
    return none;
  } finally {
    client.close();
  }
}

/// Picks the show's website out of the start of an RSS feed (exposed for tests).
String parseFeedWebsite(String xml) {
  var head = xml;
  final item = head.indexOf('<item');
  if (item >= 0) head = head.substring(0, item);
  // the <image> block has its own <link>, which is often the cover's address
  head = head.replaceAll(RegExp(r'<image>.*?</image>', dotAll: true), '');
  final link = _unescape(RegExp(r'<link(?:\s[^>]*)?>(.*?)</link>', dotAll: true).firstMatch(head)?.group(1) ?? '');
  return link.startsWith('http') ? link : '';
}

// ── Apple's podcast directory ──

/// Their shows in Apple's directory: searched by author, kept only when the author name really matches.
Future<(List<OnlineShow>, String)> appleShows(String name) async {
  final j = await _getJson(
    Uri.https('itunes.apple.com', '/search', {
      'media': 'podcast',
      'entity': 'podcast',
      'attribute': 'authorTerm',
      'limit': '50',
      'term': name,
    }),
  );
  final list = j is Map && j['results'] is List ? j['results'] as List : const [];
  final shows = <OnlineShow>[];
  final seen = <String>{};
  var artistUrl = '';
  for (final e in list.whereType<Map>()) {
    final author = '${e['artistName'] ?? ''}';
    if (!sameMaker(author, name)) continue;
    final title = '${e['collectionName'] ?? ''}';
    if (title.isEmpty || !seen.add(normName(title))) continue;
    if (artistUrl.isEmpty && '${e['artistViewUrl'] ?? ''}'.startsWith('http')) {
      artistUrl = '${e['artistViewUrl']}'.replaceAll(RegExp(r'\?.*$'), '');
    }
    shows.add(
      OnlineShow(
        title: title,
        author: author,
        feedUrl: '${e['feedUrl'] ?? ''}',
        artwork: '${e['artworkUrl600'] ?? e['artworkUrl100'] ?? ''}',
        genre: '${e['primaryGenreName'] ?? ''}',
        episodes: (e['trackCount'] as num?)?.toInt(),
        appleUrl: '${e['collectionViewUrl'] ?? ''}'.replaceAll(RegExp(r'\?.*$'), ''),
        artistId: '${e['artistId'] ?? ''}',
      ),
    );
  }
  return (shows, artistUrl);
}

// ── Wikipedia ──

final _media = RegExp(
  r'podcast|broadcast|radio|television|\btv\b|journalist|presenter|\bhost\b|comedian|commentator|media|news|'
  r'network|publisher|newspaper|magazine|youtuber|personality|writer|author|storyteller|program',
);

/// A Wikipedia summary, its address and picture, when the article is about a podcast or media maker.
/// [shows] are their show titles: an article that names one of them is surely the right one.
Future<({String about, String url, String image})> podcasterWiki(String name, List<String> shows) async {
  final none = (about: '', url: '', image: '');
  final titles = [
    name,
    '$name (podcast)',
    '$name (podcaster)',
    '$name (broadcaster)',
    '$name (journalist)',
    '$name (comedian)',
  ];
  final showNames = [for (final s in shows) normName(s)]..removeWhere((s) => s.length < 4);
  for (final title in titles) {
    try {
      final j = await _getJson(
        Uri.https('en.wikipedia.org', '/api/rest_v1/page/summary/${Uri.encodeComponent(title.replaceAll(' ', '_'))}'),
      );
      if (j is! Map || j['type'] == 'disambiguation') continue;
      final desc = '${j['description'] ?? ''}'.toLowerCase();
      final extract = '${j['extract'] ?? ''}'.trim();
      final text = normName('$desc $extract');
      final namesShow = showNames.any(text.contains);
      if (!namesShow && !_media.hasMatch(desc)) continue;
      if (extract.isEmpty) continue;
      final img = '${(j['thumbnail'] as Map?)?['source'] ?? ''}';
      return (
        about: extract,
        url: '${((j['content_urls'] as Map?)?['mobile'] as Map?)?['page'] ?? ''}',
        image: img.startsWith('http') ? img : '',
      );
    } catch (_) {}
  }
  return none;
}

// ── All of it, kept on the phone ──

Map<String, dynamic> _store() {
  try {
    return (jsonDecode(prefs.getString('podcasterCache') ?? '{}') as Map).cast<String, dynamic>();
  } catch (_) {
    return {};
  }
}

/// The phone's copy for [name] (or null), and whether it's less than a week old.
(PodcasterInfo?, bool) cachedPodcaster(String name) {
  final e = _store()[normName(name)];
  if (e is! Map || e['info'] is! Map) return (null, false);
  final at = DateTime.fromMillisecondsSinceEpoch((e['at'] as num?)?.toInt() ?? 0);
  return (
    PodcasterInfo.fromJson((e['info'] as Map).cast<String, dynamic>()),
    DateTime.now().difference(at) < const Duration(days: 7),
  );
}

void _keep(String name, PodcasterInfo info) {
  final m = _store();
  m[normName(name)] = {'at': DateTime.now().millisecondsSinceEpoch, 'info': info.toJson()};
  // keep it small: the 60 most recent
  if (m.length > 60) {
    final keys = m.keys.toList()
      ..sort((a, b) => (((m[a] as Map?)?['at'] as num?) ?? 0).compareTo(((m[b] as Map?)?['at'] as num?) ?? 0));
    for (final k in keys.take(m.length - 60)) {
      m.remove(k);
    }
  }
  prefs.setString('podcasterCache', jsonEncode(m));
}

/// Looks everything up for [name]. [feeds] are the feed addresses of their shows you follow, [myShows] the titles.
/// Never throws: a lookup that finds nothing just leaves its part empty.
Future<PodcasterInfo> fetchPodcaster(
  String name, {
  List<String> feeds = const [],
  List<String> myShows = const [],
}) async {
  final results = await Future.wait<Object?>([
    appleShows(name).catchError((_) => (const <OnlineShow>[], '')),
    feeds.isEmpty ? Future.value('') : feedWebsite(feeds.first).catchError((_) => ''),
  ]);
  final (shows, artistUrl) = results[0] as (List<OnlineShow>, String);
  final website = results[1] as String;
  final wiki = await podcasterWiki(name, [
    ...myShows,
    ...shows.map((s) => s.title),
  ]).catchError((_) => (about: '', url: '', image: ''));
  final info = PodcasterInfo(
    about: wiki.about,
    wikiUrl: wiki.url,
    image: wiki.image,
    website: website,
    appleUrl: artistUrl,
    shows: shows,
  );
  if (!info.isEmpty) _keep(name, info);
  return info;
}
