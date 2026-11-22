import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'embedded_lyrics.dart';
import 'local_files.dart';
import 'models.dart';
import 'online_lyrics.dart';
import 'saved_lyrics.dart';
import 'subsonic.dart';

/// Finding a song's lyrics, and keeping them on this device for the downloads and the files on this device
/// (saved_lyrics.dart). Shared code: the player (lyricsProvider) and the downloads (which fill in lyrics with
/// the songs) both go through here.
///
/// The order: the lyrics picked by hand (Choose lyrics), then a file's own (its tags, a .lrc beside it), then
/// your server's (timed ones first), then the online sources when they're on.

/// What a look-up may use.
class LyricsAsk {
  const LyricsAsk({
    required this.server,
    this.client,
    this.online = false,
    this.sources = const [],
    this.localUri,
    this.keep = false,
    this.store,
  });

  /// Whose songs: the server's address ([SavedLyrics.localServer] for a file on this device).
  final String server;
  final SubsonicClient? client;
  final bool online; // the server (and the internet) can be reached
  final List<String> sources; // the online sources to ask, in order (empty: off)
  final String? localUri; // a file on this device: its path or content:// address
  final bool keep; // save what's found (the song is downloaded, or a file on this device)
  final SavedLyrics? store;

  SavedLyrics? get _store => store ?? savedLyrics;
  String get _sources => online ? sources.join(',') : '';
}

/// The server to file a song's lyrics under.
String lyricsServer(String songId, SubsonicClient? c) =>
    isLocalFileId(songId) ? SavedLyrics.localServer : (c?.creds.base ?? '');

/// The lyrics of [s]: the saved copy when there is one (always offline, and as the quick answer online);
/// otherwise looked up now (and kept when [LyricsAsk.keep]). A saved copy that's old is looked up again in the
/// background; [changed] is called when that brought something new.
Future<Lyrics> songLyrics(Song s, LyricsAsk a, {void Function()? changed, DateTime? now}) async {
  final at = now ?? DateTime.now();
  final store = a._store;
  final pick = pickedLyrics(s.id) ?? '';
  final saved = a.keep && store != null ? await store.read(a.server, s.id) : null;
  if (saved != null && (!a.online || saved.matches(pick, a._sources))) {
    if (a.online && saved.staleAt(at)) {
      unawaited(
        _lookUpAndKeep(s, a, saved, pick, at).then((fresh) {
          if (fresh != null && !_same(fresh, saved.lyrics)) changed?.call();
        }),
      );
    }
    return saved.lyrics;
  }
  if (!a.online && a.localUri == null) return saved?.lyrics ?? const Lyrics();
  return await _lookUpAndKeep(s, a, saved, pick, at) ?? saved?.lyrics ?? const Lyrics();
}

/// Fills in the saved lyrics of a downloaded song when they're missing, old, or made from another hand-picked
/// choice. True when it asked (so a pass over many songs can pause between them); false when there was nothing
/// to do; null when the server or the internet couldn't be reached (a pass stops there and carries on later).
Future<bool?> keepLyrics(Song s, LyricsAsk a, {DateTime? now}) async {
  final store = a._store;
  if (store == null) return false;
  final at = now ?? DateTime.now();
  final pick = pickedLyrics(s.id) ?? '';
  final saved = await store.read(a.server, s.id);
  if (saved != null && saved.matches(pick, a._sources) && (!a.online || !saved.staleAt(at))) return false;
  final shown = saved == null ? _shown.remove('${a.server}|${s.id}') : null;
  if (shown != null && shown.matches(pick, a._sources) && !shown.staleAt(at)) {
    await store.write(a.server, s.id, shown); // just shown in the player: kept as they were, nothing asked
    return false;
  }
  if (!a.online && a.localUri == null) return false;
  return await _lookUpAndKeep(s, a.keep ? a : _withKeep(a), saved, pick, at) == null ? null : true;
}

LyricsAsk _withKeep(LyricsAsk a) => LyricsAsk(
  server: a.server,
  client: a.client,
  online: a.online,
  sources: a.sources,
  localUri: a.localUri,
  keep: true,
  store: a.store,
);

/// Looks the lyrics up and keeps them (when asked to). Null when nothing could be asked (no server, no network):
/// that's never kept as "none found". Lyrics found before aren't replaced by "none" (a source that's gone
/// quiet), only checked again later.
Future<Lyrics?> _lookUpAndKeep(Song s, LyricsAsk a, SavedLyric? saved, String pick, DateTime at) async {
  final Lyrics l;
  try {
    l = await lookUpLyrics(s, a);
  } catch (_) {
    return null;
  }
  final store = a._store;
  if (!a.keep) _remember('${a.server}|${s.id}', SavedLyric(lyrics: l, at: at, pick: pick, sources: a._sources));
  if (a.keep && store != null) {
    try {
      if (l.isEmpty && saved != null && !saved.none && saved.pick == pick) {
        await store.write(a.server, s.id, saved.copy(at: at));
        return saved.lyrics;
      }
      final same = saved != null && _same(saved.lyrics, l);
      await store.write(
        a.server,
        s.id,
        SavedLyric(
          lyrics: l,
          at: at,
          pick: pick,
          sources: a._sources,
          translations: same ? saved.translations : const {},
        ),
      );
    } catch (_) {}
  }
  return l;
}

/// Lyrics shown lately for songs that aren't kept: if one is downloaded next, they're kept without asking again.
final _shown = <String, SavedLyric>{};

void _remember(String key, SavedLyric l) {
  _shown.remove(key);
  _shown[key] = l;
  while (_shown.length > 50) {
    _shown.remove(_shown.keys.first);
  }
}

bool _same(Lyrics a, Lyrics b) => jsonEncode(lyricsToJson(a)) == jsonEncode(lyricsToJson(b));

/// Looks [s]'s lyrics up now, with nothing saved. Throws when the server can't be reached.
Future<Lyrics> lookUpLyrics(Song s, LyricsAsk a) async {
  final picked = pickedLyrics(s.id); // chosen by hand: wins over the file's and the server's
  if (picked != null && a.online) {
    final p = await loadCandidate(picked);
    if (!p.isEmpty) return p;
  }
  final local = a.localUri;
  if (local != null) {
    // a file on this device: the server doesn't know it
    final l = await localFileLyrics(local);
    if (!l.isEmpty) return l;
    return a.online && a.sources.isNotEmpty ? onlineLyrics(s, a.sources, strict: true) : const Lyrics();
  }
  final c = a.client;
  if (c == null || !a.online) throw const SocketException('no server');
  final l = await c.lyrics(s, strict: true);
  if (l.isEmpty && a.sources.isNotEmpty) return onlineLyrics(s, a.sources, strict: true);
  return l;
}

/// The lyrics that come with a file on this device (its tags, or a .lrc beside it).
Future<Lyrics> localFileLyrics(String uri) async {
  try {
    if (uri.startsWith('content:')) {
      final r = await localSource?.readable(uri);
      if (r == null) return const Lyrics();
      try {
        return await fileLyrics(r.path, lrcText: r.lrc);
      } finally {
        if (r.temporary) {
          try {
            await File(r.path).delete();
          } catch (_) {}
        }
      }
    }
    return await fileLyrics(uri.startsWith('file:') ? Uri.parse(uri).toFilePath() : uri);
  } catch (_) {
    return const Lyrics();
  }
}
