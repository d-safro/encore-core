import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'lyrics_translation.dart' show LyricsTranslation;
import 'models.dart';

/// Lyrics kept on this device for the downloaded songs and the files on this device, next to their covers
/// (saved_covers.dart), so they show with no server. One small file a song, in a folder per server
/// (`<support>/lyrics/<server>/<song>.json`); files on this device go in `local`.
///
/// "No lyrics found" is kept too, so a song without any isn't asked about on every play: it's looked up again
/// after [noneAgain] (when online). Found lyrics are refreshed in the background after [foundAgain], or at once
/// when the lyrics picked by hand for the song change. Libretto's translations of them are kept alongside.
class SavedLyrics {
  SavedLyrics(this.dir);

  final Directory dir;

  static const noneAgain = Duration(days: 14);
  static const foundAgain = Duration(days: 60);
  static const localServer = 'local';
  static const _maxTranslations = 6;

  static Future<SavedLyrics> open(Directory dir) async {
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    return SavedLyrics(dir);
  }

  /// A server's folder: a short name from its address (which may hold a port and a path).
  Directory _serverDir(String server) => Directory(
    p.join(
      dir.path,
      server == localServer ? localServer : sha1.convert(utf8.encode(server)).toString().substring(0, 16),
    ),
  );

  static final _plainId = RegExp(r'^[A-Za-z0-9_-]{1,96}$');

  /// The file name for a song: its id when that's a safe file name (Navidrome's are), else a hash of it.
  static String fileName(String id) =>
      '${_plainId.hasMatch(id) ? id : 'h-${sha1.convert(utf8.encode(id)).toString().substring(0, 24)}'}.json';

  File _file(String server, String id) => File(p.join(_serverDir(server).path, fileName(id)));

  Future<SavedLyric?> read(String server, String id) async {
    try {
      final f = _file(server, id);
      if (!await f.exists()) return null;
      return SavedLyric.fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      return null; // damaged: looked up again
    }
  }

  Future<void> write(String server, String id, SavedLyric l) async {
    final f = _file(server, id);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsString(jsonEncode(l.toJson()));
    await tmp.rename(f.path);
  }

  /// Keeps a translation with a song's saved lyrics (only when its lyrics are kept: downloaded, or on this device).
  Future<void> addTranslation(String server, String id, String key, LyricsTranslation t) async {
    final had = await read(server, id);
    if (had == null || t.error != null) return;
    final m = {...had.translations}..remove(key);
    m[key] = t;
    while (m.length > _maxTranslations) {
      m.remove(m.keys.first);
    }
    await write(server, id, had.copy(translations: m));
  }

  Future<void> remove(String server, Iterable<String> ids) async {
    for (final id in ids) {
      try {
        await _file(server, id).delete();
      } catch (_) {}
    }
  }

  /// Drops the lyrics of a server's songs that aren't in [ids] any more (downloads removed meanwhile).
  Future<int> keepOnly(String server, Set<String> ids) async {
    final d = _serverDir(server);
    if (!await d.exists()) return 0;
    final keep = {for (final id in ids) fileName(id)};
    var n = 0;
    await for (final f in d.list()) {
      if (f is File && !keep.contains(p.basename(f.path))) {
        try {
          await f.delete();
          n++;
        } catch (_) {}
      }
    }
    return n;
  }

  /// Space taken by every server's saved lyrics.
  Future<int> bytes() async {
    var n = 0;
    try {
      await for (final f in dir.list(recursive: true)) {
        if (f is File) n += await f.length();
      }
    } catch (_) {}
    return n;
  }
}

/// Set at start-up (main.dart), like [savedCovers]; null in tests that don't use it.
SavedLyrics? savedLyrics;

/// What's saved for one song: its lyrics (empty: none were found), when they were looked up, and what they
/// were looked up with (the lyrics picked by hand, and whether online sources were on), so a change asks again.
class SavedLyric {
  const SavedLyric({
    required this.lyrics,
    required this.at,
    this.pick = '',
    this.sources = '',
    this.translations = const {},
  });

  final Lyrics lyrics;
  final DateTime at;
  final String pick; // the "Choose lyrics" key they came from ('' = automatic)
  final String sources; // the online sources asked, in order ('' = none)
  final Map<String, LyricsTranslation> translations; // see [translationKey]

  bool get none => lyrics.isEmpty;

  /// Old enough to look up again (online): soon for "none found", rarely for lyrics.
  bool staleAt(DateTime now) => now.difference(at) > (none ? SavedLyrics.noneAgain : SavedLyrics.foundAgain);

  /// Made from what's asked now: the same hand-picked choice, and (for "none found") the same online sources.
  bool matches(String pickNow, String sourcesNow) => pick == pickNow && (!none || sources == sourcesNow);

  SavedLyric copy({Lyrics? lyrics, DateTime? at, Map<String, LyricsTranslation>? translations}) => SavedLyric(
    lyrics: lyrics ?? this.lyrics,
    at: at ?? this.at,
    pick: pick,
    sources: sources,
    translations: translations ?? this.translations,
  );

  Map<String, dynamic> toJson() => {
    'at': at.millisecondsSinceEpoch,
    if (pick.isNotEmpty) 'pick': pick,
    if (sources.isNotEmpty) 'sources': sources,
    ...lyricsToJson(lyrics),
    if (translations.isNotEmpty)
      'translations': {
        for (final e in translations.entries)
          e.key: {'lines': e.value.lines, 'source': e.value.source, if (e.value.same) 'same': true},
      },
  };

  static SavedLyric? fromJson(Object? j) {
    if (j is! Map) return null;
    final tr = j['translations'];
    return SavedLyric(
      lyrics: lyricsFromJson(j),
      at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
      pick: '${j['pick'] ?? ''}',
      sources: '${j['sources'] ?? ''}',
      translations: {
        if (tr is Map)
          for (final e in tr.entries)
            if (e.value is Map) '${e.key}': LyricsTranslation.fromJson((e.value as Map).cast<String, dynamic>()),
      },
    );
  }
}

/// A translation's key: the language, romanized or not, and the lines it was made from (other lyrics: another key).
String translationKey(String lang, bool romanize, String text) =>
    '$lang|${romanize ? 'r' : 't'}|${sha1.convert(utf8.encode(text)).toString().substring(0, 12)}';

Map<String, dynamic> lyricsToJson(Lyrics l) => {
  if (l.synced) 'synced': true,
  if (l.lang.isNotEmpty) 'lang': l.lang,
  if (l.source.isNotEmpty) 'source': l.source,
  'lines': [
    for (final x in l.lines) x.start == null ? x.text : [x.start!.inMilliseconds, x.text],
  ],
};

Lyrics lyricsFromJson(Map j) => Lyrics(
  synced: j['synced'] == true,
  lang: '${j['lang'] ?? ''}',
  source: '${j['source'] ?? ''}',
  lines: [
    for (final x in (j['lines'] as List? ?? const []))
      if (x is List && x.length == 2 && x[0] is num)
        LyricLine(Duration(milliseconds: (x[0] as num).toInt()), '${x[1]}')
      else
        LyricLine(null, '$x'),
  ],
);
