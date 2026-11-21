import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/settings.dart';
import 'account.dart' show clientProvider;
import 'artist_extra.dart' show normName;
import 'episode_alerts.dart' show showReleaseAlerts;
import 'subsonic.dart';

/// Artists you follow, and what they've just released or are about to.
///
/// The list is kept under 'followedArtists' and goes through the server's sync store (data/sync.dart), which
/// belongs to your server account: the phone and the desktop see the same follows, and so does any other
/// device signed in to that account. Release dates come from MusicBrainz (it lists albums before they're out),
/// with Deezer filling in what MusicBrainz lacks and giving the ⬇ link for albums you don't have.

class FollowedArtist {
  const FollowedArtist(this.id, this.name, {this.mbid = '', this.cover = '', this.since = 0});
  final String id, name, mbid, cover; // id: the artist on your server
  final int since; // when you followed them (ms)

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'mbid': mbid, 'cover': cover, 'since': since};

  static FollowedArtist? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = '${j['id'] ?? ''}', name = '${j['name'] ?? ''}';
    if (id.isEmpty || name.isEmpty) return null;
    return FollowedArtist(
      id,
      name,
      mbid: '${j['mbid'] ?? ''}',
      cover: '${j['cover'] ?? ''}',
      since: (j['since'] as num?)?.toInt() ?? 0,
    );
  }
}

List<FollowedArtist> readFollows(SharedPreferences p) {
  try {
    return [for (final e in jsonDecode(p.getString('followedArtists') ?? '[]') as List) ?FollowedArtist.fromJson(e)];
  } catch (_) {
    return const [];
  }
}

class FollowsNotifier extends Notifier<List<FollowedArtist>> {
  @override
  List<FollowedArtist> build() => readFollows(prefs);

  bool isFollowing(String id) => state.any((a) => a.id == id);

  void toggle(FollowedArtist a) {
    state = isFollowing(a.id)
        ? state.where((x) => x.id != a.id).toList()
        : [...state, FollowedArtist(a.id, a.name, mbid: a.mbid, cover: a.cover, since: DateTime.now().millisecondsSinceEpoch)];
    prefs.setString('followedArtists', jsonEncode(state.map((a) => a.toJson()).toList()));
  }
}

final followsProvider = NotifierProvider<FollowsNotifier, List<FollowedArtist>>(FollowsNotifier.new);

// ── MusicBrainz ──

/// MusicBrainz asks for at most one request a second from an app, and a User-Agent that names the app and a
/// way to reach its makers (not the person using it).
const mbUserAgent = 'Encore/$appVersion ( https://github.com/d-safro/encore )';
const _mbGap = Duration(milliseconds: 1100);
DateTime _mbNext = DateTime.fromMillisecondsSinceEpoch(0);

/// Waits for this app's next MusicBrainz turn. Everything in Encore that calls MusicBrainz goes through here.
Future<void> mbTurn() async {
  final now = DateTime.now();
  final at = _mbNext.isAfter(now) ? _mbNext : now;
  _mbNext = at.add(_mbGap); // claimed before waiting, so two callers never get the same turn
  final wait = at.difference(now);
  if (wait > Duration.zero) await Future<void>.delayed(wait);
}

Future<dynamic> mbGet(http.Client h, String path, Map<String, String> q) async {
  await mbTurn();
  final r = await h
      .get(Uri.https('musicbrainz.org', '/ws/2/$path', {...q, 'fmt': 'json'}), headers: {'User-Agent': mbUserAgent})
      .timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw 'MusicBrainz $path: ${r.statusCode}';
  return jsonDecode(utf8.decode(r.bodyBytes));
}

/// The artist's MusicBrainz id from their name, only when MusicBrainz is sure (same name, top score).
Future<String> findMbid(http.Client h, String name) async {
  final j = await mbGet(h, 'artist', {'query': 'artist:"${name.replaceAll('"', '')}"', 'limit': '5'});
  final n = normName(name);
  for (final a in (j is Map ? j['artists'] as List? : null) ?? const []) {
    if (a is Map && (a['score'] as num? ?? 0) >= 95 && normName('${a['name']}') == n) return '${a['id']}';
  }
  return '';
}

// ── Releases ──

class Release {
  const Release({
    required this.artistId,
    required this.artist,
    required this.title,
    required this.date,
    this.type = 'album',
    this.dzId = '',
    this.ownId = '',
  });
  final String artistId, artist, title;
  final String date; // yyyy-mm-dd (or just yyyy-mm, yyyy when that's all that's known)
  final String type; // album, ep, single
  final String dzId; // the Deezer album, for the ⬇ page of an album you don't have
  final String ownId; // the album on your server, when you have it

  String get key => '$artistId|${normName(title)}';
  DateTime? get when => DateTime.tryParse(date.length == 4 ? '$date-01-01' : (date.length == 7 ? '$date-01' : date));
  bool upcoming(DateTime now) => (when ?? now).isAfter(now);

  /// Where tapping it goes: your album, the ⬇ album, or a search when neither exists yet.
  String get route => ownId.isNotEmpty
      ? '/album/$ownId'
      : dzId.isNotEmpty
      ? '/album/dz-a-$dzId'
      : '/search?q=${Uri.encodeComponent('$artist $title')}';
  String get cover => ownId.isNotEmpty ? 'al-$ownId' : (dzId.isNotEmpty ? 'dz-a-$dzId' : '');

  Map<String, dynamic> toJson() => {
    'artistId': artistId,
    'artist': artist,
    'title': title,
    'date': date,
    'type': type,
    'dzId': dzId,
    'ownId': ownId,
  };
  static Release fromJson(Map j) => Release(
    artistId: '${j['artistId'] ?? ''}',
    artist: '${j['artist'] ?? ''}',
    title: '${j['title'] ?? ''}',
    date: '${j['date'] ?? ''}',
    type: '${j['type'] ?? 'album'}',
    dzId: '${j['dzId'] ?? ''}',
    ownId: '${j['ownId'] ?? ''}',
  );
}

/// How far back "new" goes.
const releaseWindow = Duration(days: 120);
const _skipKinds = {'live', 'compilation', 'dj-mix', 'interview', 'spokenword', 'audiobook', 'audio drama'};

String _day(DateTime d) => d.toIso8601String().substring(0, 10);

/// MusicBrainz's release groups first released since [from] (studio albums, EPs, singles; not live albums or
/// compilations).
List<Release> parseMbReleases(Object? j, FollowedArtist a, DateTime from) {
  final out = <Release>[];
  final since = _day(from);
  for (final g in (j is Map ? j['release-groups'] as List? : null) ?? const []) {
    if (g is! Map) continue;
    final date = '${g['first-release-date'] ?? ''}';
    if (date.isEmpty || date.compareTo(since) < 0) continue;
    final kinds = [for (final k in (g['secondary-types'] as List?) ?? const []) '$k'.toLowerCase()];
    if (kinds.any(_skipKinds.contains)) continue;
    final type = '${g['primary-type'] ?? 'Album'}'.toLowerCase();
    if (type != 'album' && type != 'ep' && type != 'single') continue;
    out.add(Release(artistId: a.id, artist: a.name, title: '${g['title'] ?? ''}', date: date, type: type));
  }
  return out;
}

/// Deezer's albums released since [from], as (Deezer id, title, date, type).
List<(String, String, String, String)> parseDeezerAlbums(Object? j, DateTime from) {
  final since = _day(from);
  return [
    for (final e in (j is Map ? j['data'] as List? : null) ?? const [])
      if (e is Map && e['record_type'] != 'compile' && '${e['release_date'] ?? ''}'.compareTo(since) >= 0)
        ('${e['id']}', '${e['title'] ?? ''}', '${e['release_date']}', '${e['record_type'] ?? 'album'}'),
  ];
}

/// One list from both sources, newest first. MusicBrainz's date wins; Deezer adds its album link and anything
/// MusicBrainz doesn't have. [own] maps album names (normName) on your server to their ids.
List<Release> mergeReleases(
  FollowedArtist a,
  List<Release> mb,
  List<(String, String, String, String)> dz,
  Map<String, String> own,
) {
  final byName = <String, Release>{};
  for (final r in mb) {
    byName.putIfAbsent(normName(r.title), () => r);
  }
  for (final (id, title, date, type) in dz) {
    final k = normName(title);
    final had = byName[k];
    byName[k] = had == null
        ? Release(artistId: a.id, artist: a.name, title: title, date: date, type: type == 'compile' ? 'album' : type, dzId: id)
        : Release(artistId: a.id, artist: a.name, title: had.title, date: had.date, type: had.type, dzId: id);
  }
  final out = [
    for (final MapEntry(:key, :value) in byName.entries)
      own[key] == null
          ? value
          : Release(
              artistId: value.artistId,
              artist: value.artist,
              title: value.title,
              date: value.date,
              type: value.type,
              dzId: value.dzId,
              ownId: own[key]!,
            ),
  ]..sort((x, y) => y.date.compareTo(x.date));
  return out;
}

/// One artist's recent and coming releases. Either source may fail; what the other gave still counts.
/// Returns the releases and the MusicBrainz id used (found by name when the server had none).
Future<(List<Release>, String)> fetchReleases(
  http.Client h,
  FollowedArtist a, {
  required Map<String, String> own,
  DateTime? now,
}) async {
  final from = (now ?? DateTime.now()).subtract(releaseWindow);
  var mbid = a.mbid;
  var mb = <Release>[];
  var dz = <(String, String, String, String)>[];
  var anyOk = false;
  try {
    if (mbid.isEmpty) mbid = await findMbid(h, a.name);
    if (mbid.isNotEmpty) {
      final j = await mbGet(h, 'release-group', {
        'query': 'arid:$mbid AND firstreleasedate:[${_day(from)} TO *]',
        'limit': '100',
      });
      mb = parseMbReleases(j, a, from);
      anyOk = true;
    }
  } catch (_) {}
  try {
    final found = await _dzGet(h, Uri.https('api.deezer.com', '/search/artist', {'q': a.name, 'limit': '5'}));
    final n = normName(a.name);
    final hit = ((found is Map ? found['data'] as List? : null) ?? const [])
        .whereType<Map>()
        .where((e) => normName('${e['name']}') == n)
        .firstOrNull;
    if (hit != null) {
      dz = parseDeezerAlbums(await _dzGet(h, Uri.https('api.deezer.com', '/artist/${hit['id']}/albums', {'limit': '50'})), from);
    }
    anyOk = true;
  } catch (_) {}
  if (!anyOk) throw 'no source answered';
  return (mergeReleases(a, mb, dz, own), mbid);
}

Future<dynamic> _dzGet(http.Client h, Uri u) async {
  final r = await h.get(u, headers: {'User-Agent': mbUserAgent}).timeout(const Duration(seconds: 10));
  if (r.statusCode != 200) throw 'Deezer: ${r.statusCode}';
  return jsonDecode(utf8.decode(r.bodyBytes));
}

// ── The daily check, with its cache on this device ──

/// Checked at most once a day per artist. The cache, 'releaseCache', is {artistId: {at, mbid, items}}.
const releaseCheckEvery = Duration(hours: 22);

Map<String, dynamic> _cache(SharedPreferences p) {
  try {
    return (jsonDecode(p.getString('releaseCache') ?? '{}') as Map).cast<String, dynamic>();
  } catch (_) {
    return {};
  }
}

/// Everything cached for the artists you follow now, newest first.
List<Release> cachedReleases(SharedPreferences p, List<FollowedArtist> follows) {
  final c = _cache(p);
  final out = <Release>[
    for (final a in follows)
      for (final r in ((c[a.id] as Map?)?['items'] as List?) ?? const []) if (r is Map) Release.fromJson(r),
  ];
  final from = _day(DateTime.now().subtract(releaseWindow));
  return out.where((r) => r.date.compareTo(from) >= 0).toList()..sort((x, y) => y.date.compareTo(x.date));
}

/// The ones that came out since the last look and haven't been shown in a notification: what to tell you
/// about. An artist's first check only takes note (following someone shouldn't bring a flood).
/// [seen] is updated with what's returned.
List<Release> freshReleases(List<Release> items, Set<String> seen, {required bool firstCheck, DateTime? now}) {
  now ??= DateTime.now();
  final weekAgo = _day(now.subtract(const Duration(days: 7)));
  final out = <Release>[];
  for (final r in items) {
    if (r.upcoming(now) || seen.contains(r.key)) continue;
    seen.add(r.key);
    if (!firstCheck && r.date.compareTo(weekAgo) >= 0) out.add(r);
  }
  return out;
}

/// Refreshes the artists whose check is more than a day old (or all with [force]). Saves the cache and
/// returns the releases to notify about. Needs the server only to see which albums you already have.
Future<List<Release>> refreshReleases(
  SharedPreferences p,
  SubsonicClient? c, {
  bool force = false,
  http.Client? client,
  void Function()? onProgress,
}) async {
  final follows = readFollows(p);
  if (follows.isEmpty) return const [];
  final h = client ?? http.Client();
  final cache = _cache(p);
  final seen = (p.getStringList('releaseSeen') ?? const []).toSet();
  final fresh = <Release>[];
  final now = DateTime.now().millisecondsSinceEpoch;
  try {
    for (final a in follows) {
      final had = cache[a.id] as Map?;
      final at = (had?['at'] as num?)?.toInt() ?? 0;
      if (!force && now - at < releaseCheckEvery.inMilliseconds) continue;
      final own = <String, String>{};
      try {
        if (c != null) {
          for (final al in (await c.artist(a.id)).albums.where((x) => !x.isLookup)) {
            own[normName(al.name)] = al.id;
          }
        }
      } catch (_) {}
      try {
        final (items, mbid) = await fetchReleases(h, a.mbid.isEmpty ? FollowedArtist(a.id, a.name, mbid: '${had?['mbid'] ?? ''}') : a, own: own);
        cache[a.id] = {'at': now, 'mbid': mbid, 'items': items.map((r) => r.toJson()).toList()};
        fresh.addAll(freshReleases(items, seen, firstCheck: had == null));
        await p.setString('releaseCache', jsonEncode(cache));
        onProgress?.call();
      } catch (_) {
        // both sources failed: keep what we had and try again next time
      }
    }
    // forget artists you no longer follow
    cache.removeWhere((k, _) => !follows.any((a) => a.id == k));
    await p.setString('releaseCache', jsonEncode(cache));
    await p.setStringList('releaseSeen', seen.toList().reversed.take(1000).toList());
  } finally {
    if (client == null) h.close();
  }
  return fresh;
}

/// Only one check at a time in this app (the desktop's hourly timer and the screens may ask together).
Future<List<Release>>? _running;
Future<List<Release>> refreshReleasesOnce(SharedPreferences p, SubsonicClient? c, {bool force = false, void Function()? onProgress}) {
  return _running ??= refreshReleases(p, c, force: force, onProgress: onProgress).whenComplete(() => _running = null);
}

/// What the screens show: the cache at once, then the daily check in the background.
class ReleasesNotifier extends Notifier<List<Release>> {
  bool checking = false;

  @override
  List<Release> build() {
    final follows = ref.watch(followsProvider);
    final online = ref.watch(clientProvider) != null;
    if (online && follows.isNotEmpty) Future.microtask(refresh);
    return cachedReleases(prefs, follows);
  }

  Future<void> refresh({bool force = false}) async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    checking = true;
    void show() => state = cachedReleases(prefs, ref.read(followsProvider));
    try {
      final fresh = await refreshReleasesOnce(prefs, c, force: force, onProgress: show);
      await showReleaseAlerts(prefs, fresh);
    } catch (_) {
    } finally {
      checking = false;
      show();
    }
  }
}

final releasesProvider = NotifierProvider<ReleasesNotifier, List<Release>>(ReleasesNotifier.new);
