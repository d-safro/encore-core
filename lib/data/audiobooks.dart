import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../core/platform.dart';
import '../core/settings.dart';
import 'models.dart';

/// Audiobooks from Audiobookshelf (media-stack's books stack): its libraries, books and chapters, played
/// through Encore's own player (speed, sleep timer, lock screen), with your place kept on Audiobookshelf so its
/// own apps and web player carry on from there. Signed in under Settings › Audiobooks; the tab shows only then.
///
/// A book plays as its audio files in a row; each is a "song" whose id starts with `ab-`, treated like a
/// podcast episode (never scrobbled, no hearts, no autoplay: see [isPodcastId]).

const _store = FlutterSecureStorage();

class AbsAccount {
  const AbsAccount(this.base, this.token, {this.user = ''});
  final String base, token, user;
  Map<String, String> get headers => {'Authorization': 'Bearer $token'};
  Uri url(String path, [Map<String, String>? q]) => Uri.parse('$base$path').replace(queryParameters: q);
  /// Pictures and audio carry the token in the address (players and image loaders can't send headers).
  String media(String path) => '$base$path${path.contains('?') ? '&' : '?'}token=$token';
}

String absBase(String typed) {
  var b = typed.trim().replaceAll(RegExp(r'/+$'), '');
  if (b.isNotEmpty && !b.contains('://')) b = 'https://$b';
  return b;
}

/// Sign in: Audiobookshelf answers with a token kept on this device.
Future<AbsAccount> absSignIn(String address, String user, String password, {http.Client? client}) async {
  final base = absBase(address);
  final h = client ?? http.Client();
  try {
    final r = await h
        .post(Uri.parse('$base/login'), headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': user, 'password': password}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 401) throw 'Wrong username or password';
    if (r.statusCode != 200) throw 'Audiobookshelf answered ${r.statusCode}';
    final token = '${((jsonDecode(r.body) as Map)['user'] as Map?)?['token'] ?? ''}';
    if (token.isEmpty) throw "That doesn't look like Audiobookshelf";
    return AbsAccount(base, token, user: user);
  } finally {
    if (client == null) h.close();
  }
}

class AbsAccountNotifier extends Notifier<AbsAccount?> {
  @override
  AbsAccount? build() {
    _load();
    return null;
  }

  Future<void> _load() async {
    final b = await _store.read(key: 'absServer'), t = await _store.read(key: 'absToken');
    if (b != null && t != null) state = AbsAccount(b, t, user: await _store.read(key: 'absUser') ?? '');
  }

  Future<void> signIn(AbsAccount a) async {
    await _store.write(key: 'absServer', value: a.base);
    await _store.write(key: 'absToken', value: a.token);
    await _store.write(key: 'absUser', value: a.user);
    state = a;
    _tab(true);
  }

  Future<void> signOut() async {
    for (final k in ['absServer', 'absToken', 'absUser']) {
      await _store.delete(key: k);
    }
    state = null;
    _tab(false);
  }

  /// The Audiobooks tab comes with signing in and goes with signing out.
  void _tab(bool on) {
    final s = ref.read(settingsProvider);
    final tabs = [...s.navTabs]..remove('audiobooks');
    if (on && tabs.length < 5) tabs.insert(tabs.length - 1, 'audiobooks');
    ref.read(settingsProvider.notifier).update({'navTabs': tabs});
  }
}

final absAccountProvider = NotifierProvider<AbsAccountNotifier, AbsAccount?>(AbsAccountNotifier.new);

// ── What it has ──
class Chapter {
  const Chapter(this.start, this.end, this.title);
  final double start, end; // seconds into the book
  final String title;
}

class BookTrack {
  const BookTrack(this.start, this.duration, this.url, this.mime);
  final double start, duration; // where it begins in the book, and how long (s)
  final String url, mime;
}

class Book {
  const Book({
    required this.id,
    required this.title,
    this.author = '',
    this.narrator = '',
    this.duration = 0,
    this.cover = '',
    this.progress = 0,
    this.position = 0,
    this.finished = false,
    this.chapters = const [],
    this.description = '',
  });
  final String id, title, author, narrator, cover, description;
  final double duration, progress, position; // s, 0..1, s
  final bool finished;
  final List<Chapter> chapters;

  bool get started => position > 30 && !finished;

  static Book fromItem(Map j, AbsAccount a, {Map? progress}) {
    final media = (j['media'] as Map?) ?? const {};
    final meta = (media['metadata'] as Map?) ?? const {};
    final p = progress ?? (j['userMediaProgress'] as Map?) ?? const {};
    double d(Object? v) => v is num ? v.toDouble() : 0;
    return Book(
      id: '${j['id']}',
      title: '${meta['title'] ?? ''}',
      author: '${meta['authorName'] ?? (meta['authors'] is List ? (meta['authors'] as List).map((x) => x is Map ? x['name'] : '').join(', ') : '')}',
      narrator: '${meta['narratorName'] ?? ''}',
      description: '${meta['description'] ?? ''}',
      duration: d(media['duration']),
      cover: a.media('/api/items/${j['id']}/cover'),
      progress: d(p['progress']),
      position: d(p['currentTime']),
      finished: p['isFinished'] == true,
      chapters: [
        for (final c in (media['chapters'] as List? ?? const []))
          if (c is Map) Chapter(d(c['start']), d(c['end']), '${c['title'] ?? ''}'),
      ],
    );
  }
}

class AbsClient {
  AbsClient(this.a, {http.Client? client}) : _h = client ?? http.Client();
  final AbsAccount a;
  final http.Client _h;

  Future<Object?> _get(String path, [Map<String, String>? q]) async {
    final r = await _h.get(a.url(path, q), headers: a.headers).timeout(const Duration(seconds: 20));
    if (r.statusCode == 401) throw 'Signed out of Audiobookshelf: sign in again in Settings';
    if (r.statusCode != 200) throw 'Audiobookshelf answered ${r.statusCode}';
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<Object?> _post(String path, Map body) async {
    final r = await _h
        .post(a.url(path), headers: {...a.headers, 'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw 'Audiobookshelf answered ${r.statusCode}';
    return r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// Your place in each book you've started.
  Future<Map<String, Map>> progress() async {
    final me = await _get('/api/me') as Map;
    return {for (final p in (me['mediaProgress'] as List? ?? const [])) if (p is Map) '${p['libraryItemId']}': p};
  }

  /// Every book in your book libraries, by title, with your place in each.
  Future<List<Book>> books() async {
    final libs = ((await _get('/api/libraries') as Map)['libraries'] as List? ?? const [])
        .whereType<Map>()
        .where((l) => l['mediaType'] == 'book');
    final prog = await progress();
    final out = <Book>[];
    for (final l in libs) {
      final r = await _get('/api/libraries/${l['id']}/items', {'limit': '500', 'sort': 'media.metadata.title', 'minified': '1'});
      for (final j in ((r as Map)['results'] as List? ?? const []).whereType<Map>()) {
        out.add(Book.fromItem(j, a, progress: prog['${j['id']}']));
      }
    }
    return out;
  }

  Future<Book> book(String id) async => Book.fromItem(await _get('/api/items/$id', {'expanded': '1', 'include': 'progress'}) as Map, a);

  /// Start listening: Audiobookshelf's play session, with the book's audio files.
  Future<(String, List<BookTrack>, double)> play(String id) async {
    final r = await _post('/api/items/$id/play', {
      'deviceInfo': {'clientName': 'Encore', 'deviceId': 'encore-${isDesktop ? 'desktop' : 'phone'}'},
      'forceDirectPlay': true,
      'forceTranscode': false,
      'supportedMimeTypes': ['audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/flac', 'audio/ogg', 'audio/opus', 'audio/x-m4b'],
      'mediaPlayer': 'encore',
    }) as Map;
    double d(Object? v) => v is num ? v.toDouble() : 0;
    final tracks = [
      for (final t in (r['audioTracks'] as List? ?? const []))
        if (t is Map) BookTrack(d(t['startOffset']), d(t['duration']), a.media('${t['contentUrl']}'), '${t['mimeType'] ?? ''}'),
    ]..sort((x, y) => x.start.compareTo(y.start));
    return ('${r['id']}', tracks, d(r['currentTime']));
  }

  Future<void> sync(String session, double at, double listened, double duration) =>
      _post('/api/session/$session/sync', {'currentTime': at, 'timeListened': listened, 'duration': duration});

  Future<void> close(String session, double at, double duration) =>
      _post('/api/session/$session/close', {'currentTime': at, 'duration': duration});

  void dispose() => _h.close();
}

// ── Playing ──
/// The book playing now: its session and where each of its files begins.
class _Listening {
  _Listening(this.client, this.book, this.session, this.tracks);
  final AbsClient client;
  final Book book;
  final String session;
  final List<BookTrack> tracks;
  double lastAt = 0;
  DateTime lastSync = DateTime.now();
}

_Listening? _now;

/// The client the player's sessions use (tests swap in one with a mocked server).
AbsClient Function(AbsAccount a) absClientFor = AbsClient.new;
final _urls = <String, String>{};

/// The address to play an `ab-` song from (the handler asks).
String? audiobookUrl(String id) => _urls[id];

String _trackId(String book, int i) => 'ab-$book-$i';

/// Where in the book (s) a place in one of its files is.
double bookTime(List<BookTrack> tracks, int index, double pos) =>
    index < tracks.length ? tracks[index].start + pos : pos;

/// The file and the place in it for a time in the book.
(int, double) trackAt(List<BookTrack> tracks, double t) {
  for (var i = tracks.length - 1; i >= 0; i--) {
    if (t >= tracks[i].start) return (i, t - tracks[i].start);
  }
  return (0, 0);
}

/// The book's files as songs for the player.
List<Song> bookSongs(Book b, List<BookTrack> tracks) => [
  for (final (i, t) in tracks.indexed)
    Song(
      id: _trackId(b.id, i),
      title: tracks.length == 1 ? b.title : '${b.title} (${i + 1}/${tracks.length})',
      artist: b.author,
      album: b.title,
      coverArt: b.cover,
      duration: t.duration.round(),
      genre: 'Audiobook',
    ),
];

/// Play a book from where you were (or from [at] s, e.g. a chapter). [play]: the handler's playSongs, then
/// seek to (index, position).
Future<void> listen(
  AbsAccount? a,
  Book b, {
  double? at,
  List<BookTrack>? local, // the book's files on this device (book_downloads.dart): played from there
  required Future<void> Function(List<Song> songs, int index, Duration position) play,
}) async {
  await stopListening();
  var tracks = local ?? const <BookTrack>[];
  String? session;
  var current = b.position;
  AbsClient? c;
  if (a != null) {
    c = absClientFor(a);
    try {
      final r = await c.play(b.id); // a session, so your place is kept on Audiobookshelf
      session = r.$1;
      current = r.$3;
      if (local == null) tracks = r.$2;
    } catch (e) {
      c.dispose();
      c = null;
      if (local == null) rethrow; // not downloaded and no server: nothing to play
    }
  }
  if (tracks.isEmpty) throw 'This book has no audio files';
  for (final (i, t) in tracks.indexed) {
    _urls[_trackId(b.id, i)] = local != null ? Uri.file(t.url).toString() : t.url;
  }
  _now = c != null && session != null ? _Listening(c, b, session, tracks) : null;
  final (index, pos) = trackAt(tracks, at ?? current);
  _now?.lastAt = at ?? current;
  await play(bookSongs(b, tracks), index, Duration(milliseconds: (pos * 1000).round()));
}

/// The book id of an audiobook file's song id (`ab-<book>-<n>`; book ids have dashes too).
String? bookIdOf(String songId) =>
    songId.startsWith('ab-') && songId.lastIndexOf('-') > 3 ? songId.substring(3, songId.lastIndexOf('-')) : null;

/// After a restart: the queue still has a book's files, but their addresses (and the session) are gone.
/// Opens a new session for the book so they play again (nothing when you're signed out or it fails).
Future<void> reopenBooks(List<String> songIds) async {
  final ids = {for (final id in songIds) ?bookIdOf(id)};
  if (ids.isEmpty) return;
  final b = await _store.read(key: 'absServer'), t = await _store.read(key: 'absToken');
  if (b == null || t == null) return;
  final a = AbsAccount(b, t);
  for (final id in ids.take(1)) { // one book at a time is what a queue holds
    final c = absClientFor(a);
    try {
      final (session, tracks, at) = await c.play(id);
      for (final (i, tr) in tracks.indexed) {
        _urls[_trackId(id, i)] = tr.url;
      }
      // where you are: closing the session (another book, or this one from its page) saves this as your place
      _now = _Listening(c, await c.book(id), session, tracks)..lastAt = at;
    } catch (_) {
      c.dispose();
    }
  }
}

/// Keep your place on Audiobookshelf (the handler calls this every 15 s while a book plays).
Future<void> saveBookPlace(String songId, Duration position) async {
  final n = _now;
  if (n == null || !songId.startsWith('ab-${n.book.id}-')) return;
  final i = int.tryParse(songId.split('-').last) ?? 0;
  final at = bookTime(n.tracks, i, position.inMilliseconds / 1000);
  final now = DateTime.now();
  final listened = now.difference(n.lastSync).inMilliseconds / 1000;
  n.lastSync = now;
  n.lastAt = at;
  try {
    await n.client.sync(n.session, at, listened.clamp(0, 60).toDouble(), n.book.duration);
  } catch (_) {}
}

Future<void> stopListening() async {
  final n = _now;
  _now = null;
  if (n == null) return;
  try {
    await n.client.close(n.session, n.lastAt, n.book.duration);
  } catch (_) {}
  n.client.dispose();
}

final booksProvider = FutureProvider.autoDispose<List<Book>>((ref) async {
  final a = ref.watch(absAccountProvider);
  if (a == null) return const [];
  final c = AbsClient(a);
  try {
    return await c.books();
  } finally {
    c.dispose();
  }
});

final bookProvider = FutureProvider.autoDispose.family<Book, String>((ref, id) async {
  final a = ref.watch(absAccountProvider);
  if (a == null) throw 'Sign in to Audiobookshelf in Settings';
  final c = AbsClient(a);
  try {
    return await c.book(id);
  } finally {
    c.dispose();
  }
});

/// "1 h 05 min", "12 min".
String bookLength(double s) {
  final m = (s / 60).round();
  return m >= 60 ? '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min' : '$m min';
}
