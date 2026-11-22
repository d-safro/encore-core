/// The DJ: before every few songs, a line or two about the next one, written by your server's AI (Ollama)
/// and read by its voice (Piper, the dj-voice app): music-lookup's getDjLine / djAudio. Only while AI is on
/// at the server; otherwise the songs just follow each other. The music dips while the DJ talks.
library;

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
