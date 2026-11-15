import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/account.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../state.dart';
import '../widgets.dart';

/// Start a song radio (the song, then songs like it, endlessly) and show it.
Future<void> openSongRadio(BuildContext context, Song seed) async {
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SongRadioScreen(seed: seed)));
}

final _moreLikeProvider = FutureProvider.autoDispose.family<List<Song>, String>((ref, id) async {
  final c = ref.watch(clientProvider);
  if (c == null || !ref.watch(repoProvider).online) return const <Song>[];
  return c.songDiscoveries(id, count: 25);
});

class SongRadioScreen extends ConsumerStatefulWidget {
  const SongRadioScreen({super.key, required this.seed});
  final Song seed;
  @override
  ConsumerState<SongRadioScreen> createState() => _SongRadioScreenState();
}

class _SongRadioScreenState extends ConsumerState<SongRadioScreen> {
  late final Future<bool> _started = _start();

  Future<bool> _start() async {
    if (audioHandler.radioSeed?.id == widget.seed.id) return true; // already playing this radio
    try {
      return await audioHandler.songRadio(widget.seed);
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.seed;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    ref.watch(queueProvider);
    final current = ref.watch(playbackStateProvider).value?.queueIndex ?? 0;
    final more = ref.watch(_moreLikeProvider(s.id));
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: overArtBar(context), surfaceTintColor: Colors.transparent),
      body: FutureBuilder<bool>(
        future: _started,
        builder: (ctx, snap) {
          final upcoming = audioHandler.radioSeed?.id == s.id
              ? audioHandler.songs.skip(current + 1).take(40).toList()
              : const <Song>[];
          return ListView(
            children: [
              Stack(
                children: [
                  Positioned.fill(
                    child: ArtBackdrop(cover: s.coverArt, artist: s.artist, album: s.album, strength: 0.3),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + kToolbarHeight, 20, 16),
                    child: Row(
                      children: [
                        Cover(s.coverArt, size: 112, radius: 14, artist: s.artist, album: s.album),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.radio_rounded, size: 16, color: cs.primary),
                                  const SizedBox(width: 6),
                                  Text(
                                    'SONG RADIO',
                                    style: t.labelSmall?.copyWith(
                                      color: cs.primary,
                                      letterSpacing: 1.2,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.titleLarge),
                              Text('Based on ${s.artist}', style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (snap.connectionState != ConnectionState.done)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (snap.data != true)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No sound-alikes for this song yet. AudioMuse may not have analysed it; try another song.',
                  ),
                )
              else ...[
                SectionTitle('Up next', subtitle: 'Songs that sound like it. It keeps going as you listen.'),
                for (var i = 0; i < upcoming.length; i++) SongTile(upcoming[i], queueIndex: current + 1 + i),
              ],
              ...switch (more) {
                AsyncData(:final value) when value.isNotEmpty => [
                  SectionTitle('More like this, not in your library', subtitle: 'Tap to preview or download'),
                  for (final x in value) SongTile(x),
                ],
                _ => const <Widget>[],
              },
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }
}

/// Discovery rows for the Discover tab: songs you don't have, picked from what you play.
final discoveriesProvider = FutureProvider.autoDispose<List<(String, List<Song>)>>((ref) async {
  final c = ref.watch(clientProvider);
  if (c == null || !ref.watch(repoProvider).online) return const [];
  try {
    return await c.discoveries();
  } catch (_) {
    return const [];
  }
});

/// A compact card for a song you don't have: cover with a play-preview button, download on tap.
class DiscoveryCard extends ConsumerWidget {
  const DiscoveryCard(this.song, {super.key});
  final Song song;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final previewing = ref.watch(mediaItemProvider).value?.id == song.id;
    return SizedBox(
      width: 140,
      child: GestureDetector(
        onTap: () => showSongMenu(context, ref, song),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Cover(
                    song.coverArt,
                    size: double.infinity,
                    radius: 14,
                    artist: song.artist,
                    album: song.album,
                  ),
                ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Material(
                    color: cs.primary,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => audioHandler.playSongs([song], allowLookup: true),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          previewing ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
                          size: 20,
                          color: cs.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
                if (song.lookup == LookupState.downloading)
                  const Positioned(left: 6, top: 6, child: LookupBadge(LookupState.downloading)),
              ],
            ),
            const SizedBox(height: 8),
            Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
            Text(
              song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
