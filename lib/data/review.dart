import 'models.dart';

/// Your year (or month) in review, from music-lookup's getListeningReview: the listening stats' totals and
/// top 5s, plus genres, the first song, the longest run of days, the peak hour and the songs you found.
class ListeningReview {
  const ListeningReview({
    required this.stats,
    this.genres = const [],
    this.firstSong,
    this.streakDays = 0,
    this.streakFrom,
    this.peakHour,
    this.discoveries = const [],
    this.discoveryCount = 0,
  });
  final ListeningStats stats;
  final List<(String, int)> genres; // name, minutes
  final Song? firstSong;
  final int streakDays;
  final DateTime? streakFrom;
  final int? peakHour; // 0–23
  final List<(Song, int)> discoveries; // first heard in this period, played 10+ times
  final int discoveryCount;

  bool get isEmpty => stats.isEmpty;

  factory ListeningReview.fromJson(Map<String, dynamic> j) {
    int n(dynamic v) => v is num ? v.toInt() : 0;
    List<Map<String, dynamic>> list(dynamic v) =>
        [for (final x in (v as List? ?? const [])) if (x is Map) x.cast<String, dynamic>()];
    final streak = j['streak'] is Map ? (j['streak'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    return ListeningReview(
      stats: ListeningStats.fromJson(j),
      genres: [for (final g in list(j['genre'])) ('${g['name'] ?? ''}', n(g['minutes']))],
      firstSong: j['firstSong'] is Map ? Song.fromJson((j['firstSong'] as Map).cast<String, dynamic>()) : null,
      streakDays: n(streak['days']),
      streakFrom: DateTime.tryParse('${streak['from'] ?? ''}'),
      peakHour: j['peakHour'] is num ? n(j['peakHour']) : null,
      discoveries: [for (final s in list(j['discoveries'])) (Song.fromJson(s), n(s['plays']))],
      discoveryCount: n(j['discoveryCount']),
    );
  }
}

/// "9 pm", "midnight", "noon".
String hourLabel(int h) => switch (h) {
  0 => 'midnight',
  12 => 'noon',
  < 12 => '$h am',
  _ => '${h - 12} pm',
};

/// "12,345".
String thousands(int v) {
  final s = '$v';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Whether to offer the year in review now: from 1 December on, for this year (once a year for the notice).
bool reviewSeason(DateTime now) => now.month == 12;
