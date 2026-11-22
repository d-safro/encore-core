import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'library.dart';
import 'local_files.dart' show isLocalFileId;
import 'saved_lyrics.dart';
import 'song_lyrics.dart' show lyricsServer;
import 'account.dart';
import 'subsonic.dart';

/// Lyrics translated (or romanized) by the server's local AI (music-lookup's translateLyrics, run by Ollama:
/// nothing leaves the house). One line comes back for each line shown; blank lines stay blank.
class LyricsTranslation {
  final List<String> lines;
  final String source; // the lyrics' language, e.g. "ja"
  final bool same; // already in that language (or nothing to romanize): no second lines
  final String? error; // why there's none: see [lyricsTranslationProblem]
  const LyricsTranslation({this.lines = const [], this.source = '', this.same = false, this.error});

  factory LyricsTranslation.fromJson(Map<String, dynamic> j) => LyricsTranslation(
    lines: [for (final l in (j['lines'] as List? ?? const [])) '$l'],
    source: '${j['source'] ?? ''}',
    same: j['same'] == true,
    error: j['error'] as String?,
  );

  /// The second line under line [i], or null (blank, or not translated).
  String? under(int i, String original) {
    if (i >= lines.length) return null;
    final t = lines[i].trim();
    return t.isEmpty || t == original.trim() ? null : t;
  }
}

/// The languages you can translate into (Settings › Lyrics).
const lyricsLanguages = {
  'en': 'English', 'es': 'Spanish', 'fr': 'French', 'de': 'German', 'it': 'Italian', 'pt': 'Portuguese',
  'nl': 'Dutch', 'ru': 'Russian', 'uk': 'Ukrainian', 'pl': 'Polish', 'tr': 'Turkish', 'ar': 'Arabic',
  'he': 'Hebrew', 'hi': 'Hindi', 'ja': 'Japanese', 'ko': 'Korean', 'zh': 'Chinese', 'sv': 'Swedish',
};

/// The language translations go into: the one picked in Settings, else the phone's (else English).
String lyricsTargetLanguage(String picked, [String? device]) {
  if (lyricsLanguages.containsKey(picked)) return picked;
  final d = device ?? PlatformDispatcher.instance.locale.languageCode;
  return lyricsLanguages.containsKey(d) ? d : 'en';
}

/// Lyrics written in another alphabet (Japanese, Korean, Chinese, Cyrillic, Arabic, Hebrew, Hindi, Greek):
/// these can also be shown romanized.
/// (Credit lines, see [isCreditLine], don't count.)
bool needsRomanizing(Iterable<String> lines, {String title = '', String artist = ''}) {
  final other = RegExp(r'[Ͱ-ϿЀ-ӿ֐-ۿऀ-ॿ぀-ヿ㐀-鿿가-힯]');
  final sung = sungLines(lines, title: title, artist: artist);
  return sung.isNotEmpty && sung.where(other.hasMatch).length * 3 >= sung.length; // a third of the lines or more
}

/// The lines that are sung: not empty, not credits ([isCreditLine], or a "Title - Artist (…)" line at the top).
List<String> sungLines(Iterable<String> lines, {String title = '', String artist = ''}) {
  final out = <String>[];
  for (final l in lines) {
    if (l.trim().isEmpty || isCreditLine(l, title: title, artist: artist, first: out.isEmpty)) continue;
    out.add(l);
  }
  return out;
}

/// Not a sung line: "Title - Artist (…)" at the top of lyrics found online (e.g. "Test Song - Test Band
/// (测试乐队)"), "Written by …", "作词 : …".
/// [first]: the first line with words (a "Song - Band (…)" line there is a credit even when the names
/// differ from the song's here).
bool isCreditLine(String line, {String title = '', String artist = '', bool first = false}) {
  final l = line.trim().toLowerCase();
  if (l.isEmpty) return false;
  if (first && RegExp(r'^[^()]+\s[-–—]\s[^()]+\([^()]+\)$').hasMatch(l)) return true;
  if (RegExp(r'^((written|lyrics|words|music|composed|produced|arranged) by\b|(作词|作曲|编曲|作詞|編曲|词|曲)\s*[:：])').hasMatch(l)) {
    return true;
  }
  final t = title.trim().toLowerCase(), a = artist.trim().toLowerCase();
  return l.contains(' - ') && ((t.isNotEmpty && l.contains(t)) || (a.isNotEmpty && l.contains(a)));
}

// everyday English words other languages hardly use (not "me", "no", "a", "in", "come"...)
const _englishWords = {
  'the', 'you', 'your', "you're", 'and', 'to', 'of', 'my', 'it', "it's", "i'm", "i'll", "i've", "don't", "can't",
  "won't", 'that', 'what', 'this', 'with', 'just', 'know', 'when', 'are', 'but', 'be', 'never', 'she', 'they',
  'we', 'love', 'like', 'need', 'feel', 'baby', 'yeah', 'can', 'there', 'how', 'why', 'where', 'now',
  'out', 'back', 'get', 'got', 'time', 'night', 'heart', 'say', 'one', 'if', 'been', 'have',
};

/// Lyrics already in [lang], going by most of their sung lines (credit lines don't count): nothing to
/// translate then. Only said when it can tell: English by its everyday words, and languages with an
/// alphabet of their own; false otherwise (the server then says whether they're already in it).
bool lyricsAlreadyIn(Iterable<String> lines, String lang, {String title = '', String artist = ''}) {
  final sung = [for (final l in sungLines(lines, title: title, artist: artist)) l.toLowerCase()];
  if (sung.isEmpty) return false;
  final kana = RegExp(r'[぀-ヿ]'), han = RegExp(r'[㐀-鿿]'), hangul = RegExp(r'[가-힯]');
  final notLatin = RegExp(r'[Ͱ-ϿЀ-ӿ֐-ۿऀ-ॿ぀-ヿ㐀-鿿가-힯]');
  final bool Function(String) isIn = switch (lang) {
    'en' => (l) =>
        !notLatin.hasMatch(l) && RegExp(r"[a-z']+").allMatches(l).any((m) => _englishWords.contains(m[0])),
    'ja' => (l) => kana.hasMatch(l),
    'zh' => (l) => han.hasMatch(l) && !kana.hasMatch(l) && !hangul.hasMatch(l),
    'ko' => (l) => hangul.hasMatch(l),
    'he' => (l) => RegExp(r'[֐-׿]').hasMatch(l),
    'ar' => (l) => RegExp(r'[؀-ۿ]').hasMatch(l),
    'hi' => (l) => RegExp(r'[ऀ-ॿ]').hasMatch(l),
    _ => (_) => false,
  };
  return sung.where(isIn).length * 2 > sung.length;
}

/// The lines as sent to be translated: credit lines left blank (they'd make the lyrics look like another
/// language), so they get no second line.
String linesToTranslate(Iterable<String> lines, {String title = '', String artist = ''}) {
  final out = <String>[];
  var first = true; // no line with words yet
  for (final l in lines) {
    if (l.trim().isEmpty) {
      out.add(l);
    } else if (isCreditLine(l, title: title, artist: artist, first: first)) {
      out.add('');
    } else {
      first = false;
      out.add(l);
    }
  }
  return out.join('\n');
}

/// What to tell you when there's no translation.
String lyricsTranslationProblem(String? error) => switch (error) {
  'ai-off' => 'Your server\'s AI is off. Turn it on there for Libretto to translate lyrics',
  'no-server' => 'Your server can\'t translate lyrics (Libretto needs Conductor or music-lookup)',
  'offline' => 'Libretto needs your server to translate these lyrics; they weren\'t translated before',
  'private' => 'Libretto doesn\'t translate files on this device: they stay private',
  _ => 'Couldn\'t translate these lyrics. Try again later',
};

/// [text] is the lines shown, joined with newlines (a String, so equal lyrics are the same key).
typedef LyricsTranslationKey = ({String id, bool romanize, String text});

/// The translation of the lyrics shown for a song (the lines go with the key, so lyrics picked by hand or
/// found online are translated too).
final lyricsTranslationProvider = FutureProvider.autoDispose.family<LyricsTranslation, LyricsTranslationKey>((
  ref,
  k,
) async {
  ref.cacheFor(const Duration(hours: 1));
  // a file on this device stays private: its lyrics never go to the server to be translated
  if (isLocalFileId(k.id)) return const LyricsTranslation(error: 'private');
  final c = ref.watch(clientProvider);
  final lang = lyricsTargetLanguage(ref.watch(settingsProvider.select((s) => s.lyricsLanguage)));
  final offline = ref.watch(offlineProvider);
  // kept with the lyrics of a downloaded song (or a file on this device): shown offline too, and not asked again
  final server = lyricsServer(k.id, c), key = translationKey(lang, k.romanize, k.text);
  final kept = (await savedLyrics?.read(server, k.id))?.translations[key];
  if (kept != null) return kept;
  if (c == null) return const LyricsTranslation(error: 'failed');
  if (offline) return const LyricsTranslation(error: 'offline');
  try {
    final t = await c.translateLyrics(k.id, k.text.split('\n'), lang: lang, romanize: k.romanize);
    if (t.error == null) unawaited(savedLyrics?.addTranslation(server, k.id, key, t).catchError((_) {}));
    return t;
  } on SubsonicException catch (e) {
    // Navidrome on its own doesn't know the call
    return LyricsTranslation(error: e.code == 70 || e.message.contains(' 404') ? 'no-server' : 'failed');
  } catch (_) {
    return const LyricsTranslation(error: 'failed');
  }
});
