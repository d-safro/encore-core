import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/account.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../playback/handler.dart';
import 'actions.dart';
import 'state.dart';

/// Album / song / artist artwork from the server, cached on the phone.
class Cover extends ConsumerWidget {
  const Cover(this.coverArt, {super.key, this.size = 56, this.radius = 8, this.icon = Icons.album, this.circle = false});
  final String coverArt;
  final double size, radius;
  final IconData icon;
  final bool circle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(clientProvider);
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: cs.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(icon, color: cs.onSurfaceVariant, size: size.isFinite ? size * 0.45 : 48),
    );
    final px = size.isFinite ? (size * MediaQuery.devicePixelRatioOf(context)).round().clamp(100, 1200) : 800;
    final bucket = px <= 200 ? 200 : (px <= 500 ? 500 : 1000);
    final img = coverArt.isEmpty || c == null
        ? placeholder
        : CachedNetworkImage(
            imageUrl: c.coverUrl(coverArt, size: bucket).toString(),
            cacheKey: '${c.creds.base}|$coverArt|$bucket',
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 150),
            placeholder: (_, _) => placeholder,
            errorWidget: (_, _, _) => placeholder,
          );
    final box = SizedBox(width: size, height: size, child: img);
    return circle ? ClipOval(child: box) : ClipRRect(borderRadius: BorderRadius.circular(radius), child: box);
  }
}

/// Builds the right thing for loading / error / data.
class AsyncView<T> extends StatelessWidget {
  const AsyncView(this.value, this.builder, {super.key, this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => value.when(
        data: builder,
        loading: () => const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.cloud_off, size: 40, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 8),
              Text('$e', textAlign: TextAlign.center),
              if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Try again')),
            ]),
          ),
        ),
      );
}

class LookupBadge extends StatelessWidget {
  const LookupBadge(this.state, {super.key});
  final LookupState state;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color, tip) = switch (state) {
      LookupState.downloading => (Icons.hourglass_top_rounded, cs.tertiary, 'Downloading'),
      LookupState.failed => (Icons.error_outline, cs.error, 'Couldn\'t download'),
      _ => (Icons.cloud_download_outlined, cs.primary, 'Not in your library'),
    };
    return Tooltip(message: tip, child: Icon(icon, size: 18, color: color));
  }
}

/// One song row. Taps play [list] from this song; long press / ⋮ opens the song menu.
class SongTile extends ConsumerWidget {
  const SongTile(this.song,
      {super.key, this.list, this.index, this.showCover = true, this.showTrack = false, this.queueIndex, this.trailing});
  final Song song;
  final List<Song>? list;
  final int? index, queueIndex;
  final bool showCover, showTrack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(mediaItemProvider).value?.id == song.id;
    final dl = ref.watch(downloadsProvider);
    final progress = dl.progress[song.id];
    final offline = ref.watch(offlineProvider);
    final available = !offline || dl.files.containsKey(song.id);
    final cs = Theme.of(context).colorScheme;
    final titleStyle = TextStyle(
      color: current ? cs.primary : (song.isLookup || !available ? cs.onSurfaceVariant : null),
      fontWeight: current ? FontWeight.w600 : null,
    );
    return ListTile(
      enabled: available || song.isLookup,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: showTrack
          ? SizedBox(
              width: 32,
              child: Center(
                  child: current
                      ? Icon(Icons.graphic_eq, color: cs.primary)
                      : Text('${song.track ?? ''}', style: Theme.of(context).textTheme.bodyMedium)))
          : (showCover ? Cover(song.coverArt, size: 48, radius: 6, icon: Icons.music_note) : null),
      title: Row(children: [
        if (song.isLookup) Padding(padding: const EdgeInsets.only(right: 6), child: LookupBadge(song.lookup)),
        Expanded(child: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle)),
      ]),
      subtitle: Row(children: [
        if (dl.files.containsKey(song.id))
          Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.offline_pin, size: 14, color: cs.primary)),
        if (song.starred) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.favorite, size: 14, color: cs.primary)),
        Expanded(
          child: Text(
            [showTrack ? '' : song.artist, formatDuration(song.duration)].where((e) => e.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
      trailing: trailing ??
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (progress != null)
              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, value: progress > 0 ? progress : null)),
            IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showSongMenu(context, ref, song, queueIndex: queueIndex)),
          ]),
      onTap: () {
        if (queueIndex != null) {
          audioHandler.skipToQueueItem(queueIndex!);
        } else if (song.isLookup) {
          showSongMenu(context, ref, song);
        } else {
          final l = list ?? [song];
          audioHandler.playSongs(l, index: index ?? l.indexOf(song));
        }
      },
      onLongPress: () => showSongMenu(context, ref, song, queueIndex: queueIndex),
    );
  }
}

class AlbumCard extends ConsumerWidget {
  const AlbumCard(this.album, {super.key, this.width = 150, this.showArtist = true, this.showYear = false});
  final Album album;
  final double width;
  final bool showArtist, showYear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/album/${album.id}'),
        onLongPress: () => showCollectionMenu(context, ref, album.name,
            () async => (await ref.read(repoProvider).album(album.id)).songs),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(children: [
              AspectRatio(aspectRatio: 1, child: Cover(album.coverArt, size: double.infinity, radius: 10)),
              if (album.isLookup) Positioned(right: 6, top: 6, child: _Pill(child: LookupBadge(album.lookup))),
            ]),
            const SizedBox(height: 6),
            Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
            if (showArtist || showYear)
              Text(
                [if (showArtist) album.artist, if (showYear && album.year != null) '${album.year}'].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall,
              ),
          ]),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85), shape: BoxShape.circle),
        child: child,
      );
}

/// A titled horizontal carousel (home screen, artist page).
class Shelf extends StatelessWidget {
  const Shelf({super.key, required this.title, required this.children, this.onMore, this.height = 210});
  final String title;
  final List<Widget> children;
  final VoidCallback? onMore;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
        child: Row(children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
          if (onMore != null) IconButton(icon: const Icon(Icons.chevron_right), onPressed: onMore),
        ]),
      ),
      SizedBox(
        height: height,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: children.length,
          separatorBuilder: (_, _) => const SizedBox(width: 4),
          itemBuilder: (_, i) => children[i],
        ),
      ),
    ]);
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 6),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
          ?trailing,
        ]),
      );
}

/// The bar above the navigation: what's playing, play/pause, progress. Tap opens the player.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(mediaItemProvider).value;
    if (item == null) return const SizedBox.shrink();
    final state = ref.watch(playbackStateProvider).value;
    final pos = ref.watch(positionProvider).value;
    final playing = state?.playing ?? false;
    final song = ref.watch(currentSongProvider);
    final cs = Theme.of(context).colorScheme;
    final loading = state?.processingState == AudioProcessingState.loading ||
        state?.processingState == AudioProcessingState.buffering;
    final frac = pos == null || pos.duration.inMilliseconds == 0
        ? 0.0
        : (pos.position.inMilliseconds / pos.duration.inMilliseconds).clamp(0.0, 1.0);
    return Material(
      color: cs.surfaceContainerHigh,
      child: InkWell(
        onTap: () => context.push('/player'),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: frac, minHeight: 2, backgroundColor: Colors.transparent),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            child: Row(children: [
              Hero(tag: 'cover', child: Cover(song?.coverArt ?? '', size: 44, radius: 6, icon: Icons.music_note)),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onHorizontalDragEnd: (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -300) audioHandler.skipToNext();
                    if (v > 300) audioHandler.skipToPrevious();
                  },
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                    Text(item.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
              ),
              if (song != null)
                IconButton(
                  icon: Icon(song.starred ? Icons.favorite : Icons.favorite_border),
                  onPressed: () => toggleStarSong(context, ref, song),
                ),
              loading
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)))
                  : IconButton(
                      iconSize: 32,
                      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      onPressed: playing ? audioHandler.pause : audioHandler.play,
                    ),
              IconButton(icon: const Icon(Icons.skip_next_rounded), onPressed: audioHandler.skipToNext),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Big round play + shuffle buttons used on album, playlist, artist and genre pages.
class PlayButtons extends StatelessWidget {
  const PlayButtons({super.key, required this.onPlay, required this.onShuffle, this.extra = const []});
  final VoidCallback onPlay, onShuffle;
  final List<Widget> extra;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Expanded(child: FilledButton.icon(onPressed: onPlay, icon: const Icon(Icons.play_arrow), label: const Text('Play'))),
          const SizedBox(width: 12),
          Expanded(
              child: FilledButton.tonalIcon(onPressed: onShuffle, icon: const Icon(Icons.shuffle), label: const Text('Shuffle'))),
          ...extra,
        ]),
      );
}
