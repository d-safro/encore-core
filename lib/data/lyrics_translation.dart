import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'library.dart';
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
bool needsRomanizing(Iterable<String> lines) {
  final other = RegExp(r'[Ͱ-ϿЀ-ӿ֐-ۿऀ-ॿ぀-ヿ㐀-鿿가-힯]');
  var n = 0, total = 0;
  for (final l in lines) {
    if (l.trim().isEmpty) continue;
    total++;
    if (other.hasMatch(l)) n++;
  }
  return total > 0 && n * 3 >= total; // a third of the lines or more
}

/// What to tell you when there's no translation.
String lyricsTranslationProblem(String? error) => switch (error) {
  'ai-off' => 'Your server\'s AI is off. Turn it on (homelab ai on) for Libretto to translate lyrics',
  'no-server' => 'Your server can\'t translate lyrics (Libretto needs Conductor or music-lookup)',
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
  final c = ref.watch(clientProvider);
  if (c == null) return const LyricsTranslation(error: 'failed');
  final lang = lyricsTargetLanguage(ref.watch(settingsProvider.select((s) => s.lyricsLanguage)));
  try {
    return await c.translateLyrics(k.id, k.text.split('\n'), lang: lang, romanize: k.romanize);
  } on SubsonicException catch (e) {
    // Navidrome on its own doesn't know the call
    return LyricsTranslation(error: e.code == 70 || e.message.contains(' 404') ? 'no-server' : 'failed');
  } catch (_) {
    return const LyricsTranslation(error: 'failed');
  }
});
