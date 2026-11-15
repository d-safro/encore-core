import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';

import '../core/settings.dart';
import '../data/ai.dart';
import '../data/library.dart';
import '../data/online_lyrics.dart';
import '../data/models.dart';
import '../playback/handler.dart';

// ── Playback, for the UI ──
final mediaItemProvider = StreamProvider<MediaItem?>((ref) => audioHandler.mediaItem);
final playbackStateProvider = StreamProvider<PlaybackState>((ref) => audioHandler.playbackState);
final queueProvider = StreamProvider<List<MediaItem>>((ref) => audioHandler.queue);
final playerExtrasProvider = StreamProvider<PlayerExtras>(
  (ref) => audioHandler.extras.stream.startWith(audioHandler.currentExtras),
);

class PositionData {
  final Duration position, buffered, duration;
  const PositionData(this.position, this.buffered, this.duration);
}

final positionProvider = StreamProvider<PositionData>((ref) {
  final p = audioHandler.player;
  return Rx.combineLatest3<Duration, Duration, Duration?, PositionData>(
    p.positionStream,
    p.bufferedPositionStream,
    p.durationStream,
    (pos, buf, dur) => PositionData(pos, buf, dur ?? Duration.zero),
  );
});

/// The Song behind the current media item (with heart / rating / album ids).
final currentSongProvider = Provider<Song?>((ref) {
  ref.watch(mediaItemProvider);
  ref.watch(queueProvider);
  return audioHandler.currentSong;
});

// ── Data for screens (re-fetched when the server / offline state changes) ──
final albumProvider = FutureProvider.autoDispose.family<Album, String>((ref, id) => ref.watch(repoProvider).album(id));
final artistProvider = FutureProvider.autoDispose.family<Artist, String>(
  (ref, id) => ref.watch(repoProvider).artist(id),
);
final artistInfoProvider = FutureProvider.autoDispose.family<ArtistInfo, String>((ref, id) async {
  final repo = ref.watch(repoProvider);
  return repo.online ? repo.client!.artistInfo(id) : const ArtistInfo();
});
final topSongsProvider = FutureProvider.autoDispose.family<List<Song>, String>((ref, name) async {
  final repo = ref.watch(repoProvider);
  return repo.online ? repo.client!.topSongs(name) : const <Song>[];
});
final soundAlikeArtistsProvider = FutureProvider.autoDispose.family<List<Artist>, String>((ref, name) async {
  final ai = ref.watch(aiProvider);
  if (ai == null) return const <Artist>[];
  try {
    return await ai.similarArtists(name);
  } catch (_) {
    return const <Artist>[];
  }
});
final playlistProvider = FutureProvider.autoDispose.family<Playlist, String>(
  (ref, id) => ref.watch(repoProvider).playlist(id),
);
final playlistsProvider = FutureProvider.autoDispose<List<Playlist>>((ref) => ref.watch(repoProvider).playlists());
final artistsProvider = FutureProvider.autoDispose<List<Artist>>((ref) => ref.watch(repoProvider).artists());
final genresProvider = FutureProvider.autoDispose<List<Genre>>((ref) => ref.watch(repoProvider).genres());
final starredProvider = FutureProvider.autoDispose<SearchResult>((ref) => ref.watch(repoProvider).starred());
final albumListProvider = FutureProvider.autoDispose.family<List<Album>, String>(
  (ref, type) => ref.watch(repoProvider).albums(type, size: 30),
);
final genreSongsProvider = FutureProvider.autoDispose.family<List<Song>, String>(
  (ref, g) => ref.watch(repoProvider).songsByGenre(g),
);
final genreAlbumsProvider = FutureProvider.autoDispose.family<List<Album>, String>(
  (ref, g) => ref.watch(repoProvider).albums('byGenre', size: 200, genre: g),
);
final lyricsProvider = FutureProvider.autoDispose.family<Lyrics, String>((ref, id) async {
  final repo = ref.watch(repoProvider);
  final song = audioHandler.songs.firstWhere(
    (s) => s.id == id,
    orElse: () => Song(id: id, title: ''),
  );
  if (!repo.online) return const Lyrics();
  final picked = pickedLyrics(id); // chosen by hand: wins over the server's
  if (picked != null) {
    final p = await loadCandidate(picked);
    if (!p.isEmpty) return p;
  }
  final l = await repo.client!.lyrics(song);
  final set = ref.read(settingsProvider);
  if (l.isEmpty && set.onlineLyrics) return onlineLyrics(song, set.lyricsSources);
  return l;
});
final radiosProvider = FutureProvider.autoDispose<List<InternetRadio>>((ref) async {
  final repo = ref.watch(repoProvider);
  return repo.online ? repo.client!.radios() : const <InternetRadio>[];
});
