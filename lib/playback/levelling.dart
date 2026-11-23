import 'dart:math';

import '../core/settings.dart';
import '../data/models.dart';

/// Sound levelling (ReplayGain): how many dB song [i] of [songs] is turned up or down, or null when there's
/// nothing to level it by (no gain from the file's tags or the server's measurement, or the setting is off).
///
/// Album gain in album mode (and in auto mode when a neighbour in the queue is from the same album: an album
/// played in order keeps its quiet songs quieter than its loud ones), track gain otherwise; each falls back on the
/// other. Never louder than the song's peak allows (nothing clips): with no peak known, never louder at all.
double? replayGainDb(List<Song> songs, int i, ReplayGainMode mode, double preamp) {
  if (mode == ReplayGainMode.off || i < 0 || i >= songs.length) return null;
  final song = songs[i];
  final rg = song.replayGain;
  var albumMode = mode == ReplayGainMode.album;
  if (mode == ReplayGainMode.auto && song.albumId.isNotEmpty) {
    // (songs without an album, such as podcasts or files from the phone, aren't one album together)
    albumMode = (i > 0 && songs[i - 1].albumId == song.albumId) ||
        (i + 1 < songs.length && songs[i + 1].albumId == song.albumId);
  }
  final gain = albumMode ? rg.albumGain ?? rg.trackGain : rg.trackGain ?? rg.albumGain;
  if (gain == null || !gain.isFinite) return null;
  final peak = albumMode ? rg.albumPeak ?? rg.trackPeak : rg.trackPeak ?? rg.albumPeak;
  var db = gain + preamp;
  final most = peak != null && peak > 0 && peak.isFinite ? -20 * log(peak) / ln10 : 0.0;
  return min(db, most);
}

/// [db] as a volume (linear: 1 is as it is).
double dbToVolume(double db) => pow(10, db / 20).toDouble();
