import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/appearance.dart';
import '../../core/settings.dart';
import '../../data/account.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../data/jam.dart';
import '../../data/online_lyrics.dart';
import '../../playback/audio_device.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../state.dart';
import '../widgets.dart';
import 'podcasts.dart';
import 'radio.dart';
import '../../data/cover_cache.dart';
import '../cast_sheet.dart';
import 'jam.dart';

/// Colours taken from the current album art (Material You from the cover).
final artSchemeProvider = FutureProvider.autoDispose.family<ColorScheme?, String>((ref, coverArt) async {
  final c = ref.watch(clientProvider);
  if (c == null || coverArt.isEmpty) return null;
  try {
    return await ColorScheme.fromImageProvider(
      provider: CachedNetworkImageProvider(
        c.coverUrl(coverArt, size: 200).toString(),
        cacheKey: '${c.creds.base}|$coverArt|200',
        cacheManager: coverCache,
      ),
      brightness: Brightness.dark,
    );
  } catch (_) {
    return null;
  }
});

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});
  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  bool _lyrics = false;

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(mediaItemProvider).value;
    final song = ref.watch(currentSongProvider);
    final base = Theme.of(context);
    final scheme = ref.watch(artSchemeProvider(song?.coverArt ?? '')).value;
    final theme = scheme == null
        ? base
        : base.copyWith(
            colorScheme: base.colorScheme.copyWith(
              primary: scheme.primary,
              onPrimary: scheme.onPrimary,
              primaryContainer: scheme.primaryContainer,
              onPrimaryContainer: scheme.onPrimaryContainer,
              secondaryContainer: scheme.secondaryContainer,
            ),
          );
    if (item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Nothing playing')),
      );
    }
    final look = AppLook.of(context);
    final podcast = song != null && isPodcastId(song.id);
    // episodes rarely have lyrics: they keep the big cover in the lyrics layout
    final layout = podcast && look.playerLayout == PlayerLayout.coverLyrics ? PlayerLayout.bigCover : look.playerLayout;
    final minimal = layout == PlayerLayout.minimal;
    return AnimatedTheme(
      data: theme,
      child: Builder(
        builder: (context) {
          return Scaffold(
            body: Stack(
              children: [
                if (look.playerBlur != PlayerBlur.off)
                  Positioned.fill(
                    child: ArtBackdrop(
                      cover: song?.coverArt ?? '',
                      artist: song?.artist ?? '',
                      album: song?.album ?? '',
                      strength: look.playerBlur == PlayerBlur.strong ? 0.15 : 0.45,
                    ),
                  ),
                SafeArea(
                  child: GestureDetector(
                    onVerticalDragEnd: (d) {
                      if ((d.primaryVelocity ?? 0) > 600) context.pop();
                    },
                    child: Builder(
                      builder: (context) {
                        final art = _Art(key: ValueKey('art-${item.id}'), song: song, small: minimal);
                        final main = AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: _lyrics && song != null
                              ? LyricsView(key: ValueKey('lyrics-${song.id}'), song: song)
                              : layout == PlayerLayout.coverLyrics && song != null
                              // a smaller cover with the words under it; the lyrics button shows only the words
                              ? LayoutBuilder(
                                  key: ValueKey('both-${item.id}'),
                                  builder: (ctx, box) => Column(
                                    children: [
                                      SizedBox(height: box.maxHeight * 0.48, child: art),
                                      Expanded(child: LyricsView(song: song, compact: true)),
                                    ],
                                  ),
                                )
                              : art,
                        );
                        final controls = [
                          _Titles(item: item, song: song, large: minimal),
                          const _SeekBar(),
                          const _Controls(),
                          _BottomRow(song: song, lyrics: _lyrics, onLyrics: () => setState(() => _lyrics = !_lyrics)),
                        ];
                        // landscape / tablets: cover (or lyrics) on the left, everything else on the right
                        final size = MediaQuery.sizeOf(context);
                        if (size.width > size.height && size.width >= 600) {
                          return Column(
                            children: [
                              _TopBar(song: song),
                              Expanded(
                                child: Row(
                                  children: [
                                    Expanded(child: main),
                                    Expanded(
                                      child: Center(
                                        child: SingleChildScrollView(
                                          child: Column(mainAxisSize: MainAxisSize.min, children: controls),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }
                        return Column(children: [_TopBar(song: song), Expanded(child: main), ...controls]);
                      },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.song});
  final Song? song;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = song;
    final file = s == null ? null : ref.watch(downloadsProvider.select((d) => d.files[s.id]));
    final local = file != null;
    final wifi = ref.watch(onWifiProvider);
    final set = ref.watch(settingsProvider);
    final fmt = wifi ? set.wifiFormat : set.mobileFormat;
    final radio = audioHandler.radioSeed;
    final station = audioHandler.radioStation;
    final from = station != null
        ? 'Internet radio · ${station.name}'
        : radio != null
        ? 'Song radio · ${radio.title}'
        : s != null && audioHandler.isAutoplay(s.id)
        ? autoplayLabel()
        : (s?.album ?? '');
    final quality = s == null
        ? ''
        : local
        ? 'Downloaded · ${file.split('.').last.toUpperCase()}'
        : fmt == 'raw'
        ? '${s.suffix.toUpperCase()}${s.bitRate != null ? ' · ${s.bitRate} kbps' : ''}'
        : '${fmt.toUpperCase()} · ${wifi ? set.wifiBitrate : set.mobileBitrate} kbps';
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30), onPressed: () => context.pop()),
          Expanded(
            child: Column(
              children: [
                Text(
                  from,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(quality, style: t.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          ValueListenableBuilder<CastInfo?>(
            valueListenable: castInfo,
            builder: (ctx, info, _) => IconButton(
              tooltip: info == null ? 'Play on a speaker or TV' : 'Playing on ${info.name}',
              icon: Icon(
                info == null ? Icons.cast_rounded : Icons.cast_connected_rounded,
                color: info == null ? null : Theme.of(ctx).colorScheme.primary,
              ),
              onPressed: () => showCastSheet(ctx),
            ),
          ),
          IconButton(
            tooltip: 'Jam',
            icon: Icon(
              Icons.groups_rounded,
              color: ref.watch(jamProvider).active ? Theme.of(context).colorScheme.primary : null,
            ),
            onPressed: () => showJamSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert_rounded),
            onPressed: s == null
                ? null
                : () async {
                    if (!isPodcastId(s.id)) return showSongMenu(context, ref, s);
                    final e = await ref.read(clientProvider)?.podcastEpisode(s.id).catchError((_) => null);
                    if (e != null && context.mounted) await showEpisodeMenu(context, ref, e);
                  },
          ),
        ],
      ),
    );
  }
}

class _Art extends StatelessWidget {
  const _Art({super.key, required this.song, this.small = false});
  final Song? song;
  final bool small; // the minimal layout: a small cover at the bottom left, over the big titles
  @override
  Widget build(BuildContext context) {
    final look = AppLook.of(context);
    return LayoutBuilder(
      builder: (ctx, box) {
        final size = small
            ? (box.biggest.shortestSide - 40).clamp(80.0, 168.0)
            : (box.biggest.shortestSide - 40).clamp(120.0, 520.0);
        final cover = GestureDetector(
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -300) audioHandler.skipToNext();
            if (v > 300) audioHandler.skipToPrevious();
          },
          onDoubleTap: () {
            final s = audioHandler.currentSong;
            if (s != null) audioHandler.setRating(Rating.newHeartRating(!s.starred));
          },
          child: Hero(
            tag: 'cover',
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(look.r(22)),
                boxShadow: small ? null : const [BoxShadow(color: Colors.black54, blurRadius: 48, offset: Offset(0, 20))],
              ),
              child: Cover(
                song?.coverArt ?? '',
                size: size,
                radius: small ? 14 : 22,
                icon: Icons.music_note_outlined,
                artist: song?.artist ?? '',
                album: song?.album ?? '',
              ),
            ),
          ),
        );
        if (small) {
          return Align(
            alignment: Alignment.bottomLeft,
            child: Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: cover),
          );
        }
        return Center(child: cover);
      },
    );
  }
}

class ShuffleButton extends StatelessWidget {
  const ShuffleButton({super.key, required this.kind});
  final ShuffleKind kind;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final on = kind != ShuffleKind.off;
    return IconButton(
      tooltip: switch (kind) {
        ShuffleKind.off => 'Shuffle',
        ShuffleKind.on => 'Smart shuffle',
        ShuffleKind.smart => 'Shuffle off',
      },
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(Icons.shuffle_rounded, color: on ? cs.primary : cs.onSurfaceVariant),
          if (kind == ShuffleKind.smart)
            Positioned(right: -6, top: -6, child: Icon(Icons.auto_awesome, size: 13, color: cs.primary)),
        ],
      ),
      onPressed: () {
        final next = switch (kind) {
          ShuffleKind.off => ShuffleKind.on,
          ShuffleKind.on => ShuffleKind.smart,
          ShuffleKind.smart => ShuffleKind.off,
        };
        audioHandler.setShuffleKind(next);
        toast(context, switch (next) {
          ShuffleKind.on => 'Shuffle on',
          ShuffleKind.smart => 'Smart shuffle on: songs that fit are mixed in, marked with ✦',
          ShuffleKind.off => 'Shuffle off',
        });
      },
    );
  }
}

/// Shown under the title while a smart-shuffle pick plays: keep it (save to the list) or drop it.
class SmartPickBar extends ConsumerWidget {
  const SmartPickBar(this.song, {super.key});
  final Song song;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final ctx = audioHandler.playContext;
    final keepLabel = switch (ctx?.kind) {
      'playlist' => 'Add to ${ctx!.name}',
      'starred' => 'Add to Liked songs',
      _ => 'Add to a playlist',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            Icon(Icons.auto_awesome, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Smart shuffle pick',
                style: t.labelLarge?.copyWith(color: cs.primary, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: keepLabel,
              icon: Icon(Icons.add_circle_outline_rounded, color: cs.primary),
              onPressed: () async {
                try {
                  final done = await audioHandler.keepSuggestion(song);
                  if (done != null) {
                    if (context.mounted) toast(context, done);
                  } else if (context.mounted) {
                    await addToPlaylist(context, ref, [song]);
                  }
                } catch (e) {
                  if (context.mounted) toast(context, "Couldn't save it: $e");
                }
              },
            ),
            IconButton(
              tooltip: 'Not for this mix',
              icon: Icon(Icons.remove_circle_outline_rounded, color: cs.onSurfaceVariant),
              onPressed: () async {
                await audioHandler.dropSuggestion(song);
                if (context.mounted) toast(context, "Removed. It won't be suggested for this list again");
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Titles extends ConsumerWidget {
  const _Titles({required this.item, required this.song, this.large = false});
  final MediaItem item;
  final Song? song;
  final bool large; // the minimal layout's big titles
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final s = song;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: large ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: large
                      ? t.headlineLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.1)
                      : t.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
                ),
                const SizedBox(height: 2),
                GestureDetector(
                  // a song's artist, or for an episode the show and who makes it
                  onTap: s == null
                      ? null
                      : isPodcastId(s.id)
                      ? (s.albumId.isEmpty ? null : () => context.push(podcasterPath(show: s.albumId)))
                      : s.artistId.isEmpty
                      ? null
                      : () => context.push('/artist/${s.artistId}'),
                  child: Text(
                    item.artist ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (large ? t.titleLarge : t.titleMedium)?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (s != null && !isPodcastId(s.id))
            IconButton(
              iconSize: 28,
              icon: Icon(
                s.starred ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                color: s.starred ? cs.primary : null,
              ),
              onPressed: () => toggleStarSong(context, ref, s),
            ),
        ],
      ),
    );
    if (s == null || !audioHandler.isSuggested(s.id)) return row;
    return Column(mainAxisSize: MainAxisSize.min, children: [row, SmartPickBar(s)]);
  }
}

class _SeekBar extends ConsumerStatefulWidget {
  const _SeekBar();
  @override
  ConsumerState<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<_SeekBar> {
  double? _drag;
  String _fmt(Duration d) => formatDuration(d.inSeconds);

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(positionProvider).value ?? const PositionData(Duration.zero, Duration.zero, Duration.zero);
    final max = p.duration.inMilliseconds.toDouble();
    final value = (_drag ?? p.position.inMilliseconds.toDouble()).clamp(0.0, max > 0 ? max : 1.0);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context)
                .copyWith(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
            child: Slider(
              value: value,
              max: max > 0 ? max : 1,
              secondaryTrackValue: p.buffered.inMilliseconds.toDouble().clamp(0.0, max > 0 ? max : 1.0),
              onChanged: max > 0 ? (v) => setState(() => _drag = v) : null,
              onChangeEnd: (v) {
                audioHandler.seek(Duration(milliseconds: v.round()));
                setState(() => _drag = null);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Text(
                  _fmt(Duration(milliseconds: value.round())),
                  style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                const Spacer(),
                Text(
                  '-${_fmt(p.duration - Duration(milliseconds: value.round()))}',
                  style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(playbackStateProvider).value;
    final playing = st?.playing ?? false;
    final shuffle = switch (st?.shuffleMode) {
      AudioServiceShuffleMode.group => ShuffleKind.smart,
      AudioServiceShuffleMode.all => ShuffleKind.on,
      _ => ShuffleKind.off,
    };
    final repeat = st?.repeatMode ?? AudioServiceRepeatMode.none;
    final cs = Theme.of(context).colorScheme;
    final loading =
        st?.processingState == AudioProcessingState.loading || st?.processingState == AudioProcessingState.buffering;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          ShuffleButton(kind: shuffle),
          IconButton(
            iconSize: 42,
            icon: const Icon(Icons.skip_previous_rounded),
            onPressed: audioHandler.skipToPrevious,
          ),
          SizedBox(
            width: 74,
            height: 74,
            child: FilledButton(
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
                backgroundColor: cs.onSurface,
                foregroundColor: cs.surface,
              ),
              onPressed: playing ? audioHandler.pause : audioHandler.play,
              child: loading
                  ? SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3, color: cs.surface))
                  : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 42),
            ),
          ),
          IconButton(iconSize: 42, icon: const Icon(Icons.skip_next_rounded), onPressed: audioHandler.skipToNext),
          IconButton(
            icon: Icon(
              repeat == AudioServiceRepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
              color: repeat == AudioServiceRepeatMode.none ? cs.onSurfaceVariant : cs.primary,
            ),
            onPressed: () => audioHandler.setRepeatMode(switch (repeat) {
              AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
              AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
              _ => AudioServiceRepeatMode.none,
            }),
          ),
        ],
      ),
    );
  }
}

class _BottomRow extends ConsumerWidget {
  const _BottomRow({required this.song, required this.lyrics, required this.onLyrics});
  final Song? song;
  final bool lyrics;
  final VoidCallback onLyrics;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final extras = ref.watch(playerExtrasProvider).value ?? const PlayerExtras();
    final cs = Theme.of(context).colorScheme;
    final sleeping = extras.sleepAt != null || extras.sleepAfterTrack;
    final output = ref.watch(_outputProvider).value;
    Color c(bool on) => on ? cs.primary : cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: output != null && output.$2 != 'speaker' ? cs.primary : cs.onSurfaceVariant,
            ),
            onPressed: () => showSoundPanel(context, ref),
            icon: Icon(switch (output?.$2) {
              'bluetooth' => Icons.bluetooth_audio_rounded,
              'headphones' => Icons.headphones_rounded,
              'tv' => Icons.tv_rounded,
              _ => Icons.speaker_rounded,
            }, size: 20),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(output?.$1 ?? 'This phone', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Lyrics',
                icon: Icon(Icons.lyrics_outlined, color: c(lyrics)),
                onPressed: onLyrics,
              ),
              IconButton(
                tooltip: 'Song radio',
                icon: Icon(Icons.radio_rounded, color: c(audioHandler.radioSeed != null)),
                onPressed: song == null ? null : () => openSongRadio(context, song!),
              ),
              IconButton(
                tooltip: 'Sleep timer',
                icon: Icon(sleeping ? Icons.bedtime_rounded : Icons.bedtime_outlined, color: c(sleeping)),
                onPressed: () => showSleepTimer(context, ref),
              ),
              IconButton(
                tooltip: 'Queue',
                icon: Icon(Icons.queue_music_rounded, color: cs.onSurfaceVariant),
                onPressed: () => context.push('/queue'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Where the sound plays, refreshed every few seconds while the player is open.
final _outputProvider = StreamProvider.autoDispose<(String, String)>((ref) async* {
  while (true) {
    yield await AudioDevice.output();
    await Future.delayed(const Duration(seconds: 4));
  }
});

Future<void> showSleepTimer(BuildContext context, WidgetRef ref) async {
  final extras = audioHandler.currentExtras;
  await showModalBottomSheet(
    useRootNavigator: true,
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      void set(Duration? d, {bool afterTrack = false}) {
        audioHandler.setSleepTimer(d, afterTrack: afterTrack);
        Navigator.pop(ctx);
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Sleep timer'),
                subtitle: extras.sleepAt != null
                    ? Text('Stops at ${TimeOfDay.fromDateTime(extras.sleepAt!).format(ctx)}')
                    : extras.sleepAfterTrack
                    ? const Text('Stops after this song')
                    : null,
              ),
              for (final m in [5, 10, 15, 30, 45, 60, 90])
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text('$m minutes'),
                  onTap: () => set(Duration(minutes: m)),
                ),
              ListTile(
                leading: const Icon(Icons.music_off_outlined),
                title: const Text('End of this song'),
                onTap: () => set(null, afterTrack: true),
              ),
              if (extras.sleepAt != null || extras.sleepAfterTrack)
                ListTile(leading: const Icon(Icons.close), title: const Text('Turn off'), onTap: () => set(null)),
            ],
          ),
        ),
      );
    },
  );
}

/// Sound panel: output device, system volume, boost, speed and pitch, equalizer, ReplayGain, mono/balance.
Future<void> showSoundPanel(BuildContext context, WidgetRef ref) async {
  var (vol, maxVol) = await AudioDevice.volume();
  var output = await AudioDevice.output();
  if (!context.mounted) return;
  await showModalBottomSheet(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final s = ref.watch(settingsProvider);
        final n = ref.read(settingsProvider.notifier);
        final t = Theme.of(ctx).textTheme;
        final cs = Theme.of(ctx).colorScheme;
        return StatefulBuilder(
          builder: (ctx, set) {
            Widget label(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(text, style: t.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
            );
            return SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Text('Sound', style: t.titleLarge),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Material(
                        color: cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          leading: Icon(switch (output.$2) {
                            'bluetooth' => Icons.bluetooth_audio_rounded,
                            'headphones' => Icons.headphones_rounded,
                            'tv' => Icons.tv_rounded,
                            _ => Icons.speaker_rounded,
                          }, color: cs.primary),
                          title: Text(output.$1),
                          subtitle: const Text('Playing on'),
                          trailing: FilledButton.tonal(
                            onPressed: () async {
                              await AudioDevice.showOutputSwitcher();
                              await Future.delayed(const Duration(seconds: 2));
                              output = await AudioDevice.output();
                              set(() {});
                            },
                            child: const Text('Change'),
                          ),
                        ),
                      ),
                    ),
                    label('Volume'),
                    Row(
                      children: [
                        const SizedBox(width: 12),
                        const Icon(Icons.volume_down_rounded),
                        Expanded(
                          child: Slider(
                            value: vol.toDouble().clamp(0, maxVol.toDouble()),
                            max: maxVol.toDouble(),
                            divisions: maxVol,
                            onChanged: (v) {
                              set(() => vol = v.round());
                              AudioDevice.setVolume(vol);
                            },
                          ),
                        ),
                        const Icon(Icons.volume_up_rounded),
                        const SizedBox(width: 12),
                      ],
                    ),
                    label('Speed  ${s.speed.toStringAsFixed(2)}×'),
                    Slider(value: s.speed, min: 0.5, max: 2.0, divisions: 30, onChanged: (v) => n.update({'speed': v})),
                    label('Pitch  ${s.pitch.toStringAsFixed(2)}×'),
                    Slider(value: s.pitch, min: 0.5, max: 2.0, divisions: 30, onChanged: (v) => n.update({'pitch': v})),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          ActionChip(
                            label: const Text('Reset speed & pitch'),
                            onPressed: () => n.update({'speed': 1.0, 'pitch': 1.0}),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.equalizer_rounded),
                      title: const Text('Equalizer'),
                      subtitle: Text(s.eqEnabled ? 'On' : 'Off'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        Navigator.pop(ctx);
                        context.push('/equalizer');
                      },
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.graphic_eq_rounded),
                      title: const Text('Even out loudness'),
                      subtitle: const Text('ReplayGain: songs play at the same volume'),
                      value: s.replayGain != ReplayGainMode.off,
                      onChanged: (v) =>
                          n.update({'replayGain': v ? ReplayGainMode.auto.name : ReplayGainMode.off.name}),
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.fast_forward_rounded),
                      title: const Text('Skip silence'),
                      value: s.skipSilence,
                      onChanged: (v) => n.update({'skipSilence': v}),
                    ),
                    ListTile(
                      leading: const Icon(Icons.surround_sound_rounded),
                      title: const Text('Mono audio and left/right balance'),
                      subtitle: const Text('Android\'s audio settings (they apply to every app)'),
                      trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                      onTap: () => AudioDevice.openSettings('accessibility'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.bluetooth_rounded),
                      title: const Text('Bluetooth devices'),
                      trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                      onTap: () => AudioDevice.openSettings('bluetooth'),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

/// Synced lyrics follow the song (tap a line to jump there); plain lyrics just scroll.
class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({super.key, required this.song, this.compact = false});
  final bool compact; // under the cover: smaller words, less padding
  final Song song;
  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  final _keys = <int, GlobalKey>{};
  int _current = -1;

  @override
  Widget build(BuildContext context) {
    final lyrics = ref.watch(lyricsProvider(widget.song.id));
    final pos = ref.watch(positionProvider).value?.position ?? Duration.zero;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return lyrics.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (l) {
        if (l.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('No lyrics for this song'),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.search_rounded),
                  label: const Text('Search lyrics'),
                  onPressed: () => showChooseLyrics(context, ref, widget.song),
                ),
              ],
            ),
          );
        }
        var cur = -1;
        if (l.synced) {
          for (var i = 0; i < l.lines.length; i++) {
            if ((l.lines[i].start ?? Duration.zero) <= pos) cur = i;
          }
          if (cur != _current) {
            _current = cur;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final ctx = _keys[cur]?.currentContext;
              if (ctx != null) {
                Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 300));
              }
            });
          }
        }
        return ShaderMask(
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
            stops: [0, 0.08, 0.92, 1],
          ).createShader(r),
          blendMode: BlendMode.dstIn,
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: widget.compact ? 20 : 48),
            itemCount: l.lines.length + 1,
            itemBuilder: (_, i) {
              if (i == l.lines.length) {
                return Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.source.isEmpty ? 'Lyrics from your server' : 'Lyrics from ${l.source}',
                          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                      TextButton(
                        onPressed: () => showChooseLyrics(context, ref, widget.song),
                        child: const Text('Wrong lyrics?'),
                      ),
                    ],
                  ),
                );
              }
              final line = l.lines[i];
              final active = l.synced && i == cur;
              return InkWell(
                key: _keys.putIfAbsent(i, GlobalKey.new),
                onTap: line.start == null ? null : () => audioHandler.seek(line.start!),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 200),
                    style: (l.synced ? (widget.compact ? t.titleMedium! : t.titleLarge!) : t.bodyLarge!).copyWith(
                      color: !l.synced || active ? cs.onSurface : cs.onSurface.withValues(alpha: 0.45),
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                    child: Text(line.text.isEmpty ? '♪' : line.text),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// Pick lyrics by hand from every online source (remembered for this song).
Future<void> showChooseLyrics(BuildContext context, WidgetRef ref, Song song) => showModalBottomSheet(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: _ChooseLyrics(song)),
);

class _ChooseLyrics extends ConsumerStatefulWidget {
  const _ChooseLyrics(this.song);
  final Song song;
  @override
  ConsumerState<_ChooseLyrics> createState() => _ChooseLyricsState();
}

class _ChooseLyricsState extends ConsumerState<_ChooseLyrics> {
  late final _title = TextEditingController(text: widget.song.title);
  late final _artist = TextEditingController(text: widget.song.artist);
  late Future<List<LyricsCandidate>> _results = searchLyrics(widget.song.title, widget.song.artist);

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  void _search() => setState(() => _results = searchLyrics(_title.text.trim(), _artist.text.trim()));

  void _choose(String? key) {
    pickLyrics(widget.song.id, key);
    ref.invalidate(lyricsProvider(widget.song.id));
    Navigator.pop(context);
  }

  String _len(int? s) => s == null ? '' : ' · ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final picked = pickedLyrics(widget.song.id);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                Expanded(child: Text('Choose lyrics', style: t.titleLarge)),
                if (picked != null) TextButton(onPressed: () => _choose(null), child: const Text('Back to automatic')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _title,
                    decoration: const InputDecoration(labelText: 'Title', isDense: true),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _artist,
                    decoration: const InputDecoration(labelText: 'Artist', isDense: true),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.search_rounded), onPressed: _search),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<LyricsCandidate>>(
              future: _results,
              builder: (_, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snap.data ?? const <LyricsCandidate>[];
                if (list.isEmpty) return const Center(child: Text('Nothing found. Try a shorter title.'));
                return ListView(
                  children: [
                    for (final c in list)
                      ListTile(
                        selected: c.key == picked,
                        leading: Icon(c.synced ? Icons.lyrics_rounded : Icons.notes_rounded),
                        title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${c.artist}${_len(c.seconds)} · ${lyricsSourceNames[c.source] ?? c.source}'
                          '${c.synced ? ' · synced' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        onTap: () => _choose(c.key),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(queueProvider);
    final current = ref.watch(playbackStateProvider).value?.queueIndex ?? 0;
    final songs = audioHandler.songs;
    final online = ref.watch(repoProvider).online;
    final remaining = songs.skip(current).fold<int>(0, (n, s) => n + (s.duration ?? 0));
    return Scaffold(
      appBar: AppBar(
        title: Text('Queue · ${nSongs(songs.length)}'),
        actions: [
          if (online && songs.isNotEmpty)
            IconButton(
              tooltip: 'Save as playlist',
              icon: const Icon(Icons.playlist_add),
              // autoplay's songs aren't yours: they're left out
              onPressed: () => addToPlaylist(context, ref, songs.where((s) => !audioHandler.isAutoplay(s.id)).toList()),
            ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.clear_all),
            onPressed: () async {
              if (await confirm(context, 'Clear the queue?', 'This stops playback.', ok: 'Clear')) {
                await audioHandler.clearQueue();
                if (context.mounted) context.pop();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                Text('${formatDuration(remaining)} left', style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                Consumer(
                  builder: (ctx, ref, _) {
                    final on = ref.watch(settingsProvider.select((s) => s.autoplay));
                    return FilterChip(
                      avatar: const Icon(Icons.all_inclusive, size: 16),
                      label: const Text('Autoplay'),
                      tooltip: 'When what you play runs out, keep going with songs like it',
                      selected: on,
                      onSelected: (v) => ref.read(settingsProvider.notifier).update({'autoplay': v}),
                    );
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: songs.length,
              buildDefaultDragHandles: false,
              onReorder: (a, b) {
                if (b > a) b--;
                audioHandler.moveQueueItem(a, b);
              },
              itemBuilder: (_, i) {
                final s = songs[i];
                // autoplay's songs come under their own heading, apart from what you chose
                final auto = audioHandler.isAutoplay(s.id);
                final heading = auto && (i == 0 || !audioHandler.isAutoplay(songs[i - 1].id));
                final tile = Dismissible(
                  key: ValueKey('q-$i-${s.id}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Theme.of(context).colorScheme.errorContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.remove_circle_outline),
                  ),
                  onDismissed: (_) => audioHandler.removeQueueItemAt(i),
                  child: Opacity(
                    opacity: i < current ? 0.5 : 1,
                    child: SongTile(
                      s,
                      queueIndex: i,
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.drag_handle)),
                      ),
                    ),
                  ),
                );
                if (!heading) return tile;
                return Column(
                  key: ValueKey('qh-$i-${s.id}'),
                  mainAxisSize: MainAxisSize.min,
                  children: [_AutoplayHeading(dim: i < current), tile],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// "Autoplay · Songs like …" (the player's top line while autoplay plays).
String autoplayLabel() {
  final seed = audioHandler.autoplaySeed;
  return seed == null ? 'Autoplay' : 'Autoplay · Songs like ${seed.title}';
}

/// The heading over autoplay's songs in the queue.
class _AutoplayHeading extends StatelessWidget {
  const _AutoplayHeading({this.dim = false});
  final bool dim;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final seed = audioHandler.autoplaySeed;
    return Opacity(
      opacity: dim ? 0.5 : 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Row(
          children: [
            Icon(Icons.all_inclusive, size: 18, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Autoplay', style: t.titleSmall),
                  Text(
                    seed == null ? 'Songs like what you just played' : 'Songs like ${seed.title} and what you just played',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
