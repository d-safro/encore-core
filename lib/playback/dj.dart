/// The DJ: before every few songs, a line or two about the next one, written by your server's AI (Ollama)
/// and read by its voice (Piper, the dj-voice app): music-lookup's getDjLine / djAudio. Only while AI is on
/// at the server; otherwise the songs just follow each other. The music dips while the DJ talks.
library;

import 'dart:ui' show PlatformDispatcher;

class DjLine {
  const DjLine(this.id, this.text, this.duration);
  final String id, text;
  final double duration; // seconds

  /// null when there's no line (AI off, or it failed).
  static DjLine? fromJson(Map<String, dynamic> j) {
    final id = '${j['id'] ?? ''}';
    if (id.isEmpty || j['error'] != null) return null;
    return DjLine(id, '${j['text'] ?? ''}', (j['duration'] as num?)?.toDouble() ?? 0);
  }
}

/// How often the DJ speaks (Settings): before every song, every 3rd or every 5th.
const djChoices = [1, 3, 5];

/// The languages the DJ can speak (the server has a voice for each).
const djLanguages = {
  'en': 'English', 'de': 'German', 'es': 'Spanish', 'fr': 'French', 'it': 'Italian', 'pt': 'Portuguese',
  'ru': 'Russian', 'uk': 'Ukrainian', 'pl': 'Polish', 'nl': 'Dutch', 'sv': 'Swedish', 'tr': 'Turkish', 'zh': 'Chinese',
};

/// The DJ's language: the one picked in Settings, else the phone's, else English.
String djLanguage(String picked, [String? device]) {
  if (djLanguages.containsKey(picked)) return picked;
  final d = device ?? PlatformDispatcher.instance.locale.languageCode;
  return djLanguages.containsKey(d) ? d : 'en';
}
