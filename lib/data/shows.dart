import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/settings.dart';
import 'artist_extra.dart' show normName;
import 'follows.dart';

/// An artist's next concerts, from official APIs only (no scraping):
/// - Ticketmaster's Discovery API, when you've put in a key (free from developer.ticketmaster.com). It has
///   the city, the venue and a ticket link.
/// - MusicBrainz events otherwise: no key, but fewer shows and usually no ticket link.
/// Bandsintown needs an app id they give out by agreement, and Songkick's API is closed to new users, so
/// neither is used. Results are cached for a day; when a source fails the list is just empty.

class Show {
  const Show({
    required this.artist,
    required this.date,
    this.time = '',
    this.name = '',
    this.venue = '',
    this.city = '',
    this.region = '',
    this.country = '',
    this.url = '',
    this.source = '',
  });
  final String artist, date, time, name, venue, city, region, country, url, source; // date: yyyy-mm-dd

  String get place => [venue, city, if (region.isNotEmpty && region != city) region, country].where((s) => s.isNotEmpty).join(', ');
  String get key => '${normName(artist)}|$date|${normName(venue)}';

  /// "Near me": the town you typed appears in the city, the region or the country.
  bool near(String where) {
    final w = where.trim().toLowerCase();
    if (w.isEmpty) return true;
    return [city, region, country].any((s) => s.toLowerCase().contains(w));
  }

  Map<String, dynamic> toJson() => {
    'artist': artist,
    'date': date,
    'time': time,
    'name': name,
    'venue': venue,
    'city': city,
    'region': region,
    'country': country,
    'url': url,
    'source': source,
  };
  static Show fromJson(Map j) => Show(
    artist: '${j['artist'] ?? ''}',
    date: '${j['date'] ?? ''}',
    time: '${j['time'] ?? ''}',
    name: '${j['name'] ?? ''}',
    venue: '${j['venue'] ?? ''}',
    city: '${j['city'] ?? ''}',
    region: '${j['region'] ?? ''}',
    country: '${j['country'] ?? ''}',
    url: '${j['url'] ?? ''}',
    source: '${j['source'] ?? ''}',
  );
}

String _today() => DateTime.now().toIso8601String().substring(0, 10);

/// Ticketmaster's events where this artist is one of the acts (its keyword search also finds tribute bands
/// and namesakes, so the act has to match by name).
List<Show> parseTicketmaster(Object? j, String artist, {String? today}) {
  today ??= _today();
  final n = normName(artist);
  final out = <Show>[];
  final events = (((j is Map ? j['_embedded'] : null) as Map?)?['events'] as List?) ?? const [];
  for (final e in events.whereType<Map>()) {
    final acts = (((e['_embedded'] as Map?)?['attractions'] as List?) ?? const []).whereType<Map>();
    if (!acts.any((a) => normName('${a['name']}') == n)) continue;
    final start = ((e['dates'] as Map?)?['start'] as Map?) ?? const {};
    final date = '${start['localDate'] ?? ''}';
    if (date.isEmpty || date.compareTo(today) < 0) continue;
    final v = ((((e['_embedded'] as Map?)?['venues'] as List?) ?? const []).whereType<Map>().firstOrNull) ?? const {};
    out.add(
      Show(
        artist: artist,
        date: date,
        time: '${start['localTime'] ?? ''}'.replaceFirst(RegExp(r':00$'), ''),
        name: '${e['name'] ?? ''}',
        venue: '${v['name'] ?? ''}',
        city: '${(v['city'] as Map?)?['name'] ?? ''}',
        region: '${(v['state'] as Map?)?['name'] ?? ''}',
        country: '${(v['country'] as Map?)?['name'] ?? ''}',
        url: '${e['url'] ?? ''}',
        source: 'Ticketmaster',
      ),
    );
  }
  return _dedupe(out);
}

/// MusicBrainz's events for the artist that haven't happened yet.
List<Show> parseMbEvents(Object? j, String artist, {String? today}) {
  today ??= _today();
  final out = <Show>[];
  for (final e in ((j is Map ? j['events'] : null) as List?) ?? const []) {
    if (e is! Map || e['cancelled'] == true) continue;
    final date = '${(e['life-span'] as Map?)?['begin'] ?? ''}';
    if (date.length < 10 || date.compareTo(today) < 0) continue;
    var venue = '', city = '';
    for (final r in (e['relations'] as List?) ?? const []) {
      if (r is! Map) continue;
      if (r['place'] is Map) venue = '${(r['place'] as Map)['name'] ?? ''}';
      if (r['area'] is Map) city = '${(r['area'] as Map)['name'] ?? ''}';
    }
    out.add(
      Show(
        artist: artist,
        date: date,
        time: '${e['time'] ?? ''}',
        name: '${e['name'] ?? ''}',
        venue: venue,
        city: city,
        url: 'https://musicbrainz.org/event/${e['id']}',
        source: 'MusicBrainz',
      ),
    );
  }
  return _dedupe(out);
}

List<Show> _dedupe(List<Show> l) {
  final seen = <String>{};
  return l.where((s) => seen.add(s.key)).toList()..sort((a, b) => '${a.date}${a.time}'.compareTo('${b.date}${b.time}'));
}

Future<List<Show>> fetchShows(http.Client h, String artist, {String mbid = '', String tmKey = ''}) async {
  if (tmKey.isNotEmpty) {
    final r = await h
        .get(
          Uri.https('app.ticketmaster.com', '/discovery/v2/events.json', {
            'apikey': tmKey,
            'keyword': artist,
            'classificationName': 'music',
            'sort': 'date,asc',
            'size': '100',
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw 'Ticketmaster: ${r.statusCode}';
    return parseTicketmaster(jsonDecode(utf8.decode(r.bodyBytes)), artist);
  }
  if (mbid.isEmpty) mbid = await findMbid(h, artist);
  if (mbid.isEmpty) return const [];
  return parseMbEvents(await mbGet(h, 'event', {'query': 'arid:$mbid', 'limit': '100'}), artist);
}

// ── Settings and cache ──

/// The town for "near me" and the Ticketmaster key. Synced with your other devices ('showsPrefs').
class ShowsPrefs {
  const ShowsPrefs({this.city = '', this.tmKey = ''});
  final String city, tmKey;
}

class ShowsPrefsNotifier extends Notifier<ShowsPrefs> {
  @override
  ShowsPrefs build() {
    try {
      final j = jsonDecode(prefs.getString('showsPrefs') ?? '{}') as Map;
      return ShowsPrefs(city: '${j['city'] ?? ''}', tmKey: '${j['tmKey'] ?? ''}');
    } catch (_) {
      return const ShowsPrefs();
    }
  }

  void set({String? city, String? tmKey}) {
    state = ShowsPrefs(city: (city ?? state.city).trim(), tmKey: (tmKey ?? state.tmKey).trim());
    prefs.setString('showsPrefs', jsonEncode({'city': state.city, 'tmKey': state.tmKey}));
  }
}

final showsPrefsProvider = NotifierProvider<ShowsPrefsNotifier, ShowsPrefs>(ShowsPrefsNotifier.new);

const _showsFor = Duration(hours: 24);

/// One artist's shows: from the cache when it's less than a day old (and was made with the same source).
Future<List<Show>> showsFor(String artist, {String mbid = '', required String tmKey, http.Client? client}) async {
  final k = normName(artist);
  final source = tmKey.isEmpty ? 'mb' : 'tm';
  Map cache;
  try {
    cache = jsonDecode(prefs.getString('showsCache') ?? '{}') as Map;
  } catch (_) {
    cache = {};
  }
  final had = cache[k] as Map?;
  final now = DateTime.now().millisecondsSinceEpoch;
  final today = _today();
  if (had != null && had['source'] == source && now - ((had['at'] as num?) ?? 0) < _showsFor.inMilliseconds) {
    return [
      for (final s in (had['items'] as List?) ?? const []) if (s is Map) Show.fromJson(s),
    ].where((s) => s.date.compareTo(today) >= 0).toList();
  }
  final h = client ?? http.Client();
  try {
    final items = await fetchShows(h, artist, mbid: mbid, tmKey: tmKey);
    cache[k] = {'at': now, 'source': source, 'items': items.map((s) => s.toJson()).toList()};
    // keep the cache small: drop entries over a week old
    cache.removeWhere((_, v) => v is! Map || now - ((v['at'] as num?) ?? 0) > const Duration(days: 7).inMilliseconds);
    await prefs.setString('showsCache', jsonEncode(cache));
    return items;
  } catch (_) {
    // fail quietly: the last list we had, or nothing
    return [for (final s in (had?['items'] as List?) ?? const []) if (s is Map) Show.fromJson(s)];
  } finally {
    if (client == null) h.close();
  }
}

/// Shows for one artist page: (name, MusicBrainz id).
final artistShowsProvider = FutureProvider.autoDispose.family<List<Show>, (String, String)>((ref, k) {
  final key = ref.watch(showsPrefsProvider.select((p) => p.tmKey));
  return showsFor(k.$1, mbid: k.$2, tmKey: key);
});

/// Shows for everyone you follow, soonest first. Artists are asked one after another (MusicBrainz allows one
/// request a second), and the list grows as answers come in. The bool says whether everyone has answered.
final followedShowsProvider = StreamProvider.autoDispose<(List<Show>, bool)>((ref) async* {
  final follows = ref.watch(followsProvider);
  final key = ref.watch(showsPrefsProvider.select((p) => p.tmKey));
  final all = <Show>[];
  var alive = true;
  ref.onDispose(() => alive = false);
  yield (const <Show>[], follows.isEmpty);
  for (final (i, a) in follows.indexed) {
    if (!alive) return;
    all.addAll(await showsFor(a.name, mbid: a.mbid, tmKey: key));
    all.sort((x, y) => '${x.date}${x.time}'.compareTo('${y.date}${y.time}'));
    yield (List.of(all), i == follows.length - 1);
  }
});
