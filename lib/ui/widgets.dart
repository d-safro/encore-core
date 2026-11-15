import 'dart:io';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/account.dart';
import '../data/library.dart';
import '../data/library_pins.dart';
import '../data/models.dart';
import '../data/online_art.dart';
import '../playback/handler.dart';
import 'actions.dart';
import 'state.dart';

/// Artwork: the server's cover, cached; if the server has none, one found online (iTunes / Deezer).
/// Give [artist] + [album] (or [artistImage] for a person) so the online lookup knows what to find.
class Cover extends ConsumerWidget {
  const Cover(
    this.coverArt, {
    super.key,
    this.size = 56,
    this.radius = 10,
    this.icon = Icons.album_outlined,
    this.circle = false,
    this.artist = '',
    this.album = '',
    this.artistImage = false,
  });
  final String coverArt, artist, album;
  final double size, radius;
  final IconData icon;
  final bool circle, artistImage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (size.isFinite) return _build(context, ref, size);
    // a cover that fills its space: size it to that space, so a grid card fetches a card-sized picture
    return LayoutBuilder(
      builder: (ctx, box) {
        final w = box.maxWidth.isFinite ? box.maxWidth : MediaQuery.sizeOf(ctx).width;
        return _build(ctx, ref, w, fill: true);
      },
    );
  }

  Widget _build(BuildContext context, WidgetRef ref, double side, {bool fill = false}) {
    final c = ref.watch(clientProvider);
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: cs.surfaceContainerHigh,
      alignment: Alignment.center,
      child: Icon(icon, color: cs.onSurfaceVariant.withValues(alpha: 0.6), size: (side * 0.4).clamp(16, 64)),
    );
    final canLookUp = artist.isNotEmpty && (artistImage || album.isNotEmpty);
    Widget online() =>
        canLookUp ? _OnlineCover(artistImage ? 'artist' : 'album', artist, album, placeholder) : placeholder;
    final px = (side * MediaQuery.devicePixelRatioOf(context)).round();
    final bucket = px <= 200 ? 200 : (px <= 500 ? 500 : 1000);
    final Widget img;
    if (coverArt.isEmpty || c == null) {
      img = online();
    } else {
      final key = '${c.creds.base}|$coverArt|$bucket';
      // already looked up this session: draw it straight away (no placeholder flash when scrolling back)
      final known = _coverMemo.containsKey(key);
      final AsyncValue<File?> file = known
          ? AsyncData(_coverMemo[key])
          : ref.watch(_serverCoverProvider((coverArt, bucket)));
      img = switch (file) {
        AsyncData(:final value) when value != null => Image.file(
          value,
          fit: BoxFit.cover,
          width: fill ? null : side,
          height: fill ? null : side,
          cacheWidth: px,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => online(),
        ),
        AsyncLoading() => placeholder,
        _ => online(),
      };
    }
    final box = fill ? SizedBox.expand(child: img) : SizedBox(width: side, height: side, child: img);
    return circle ? ClipOval(child: box) : ClipRRect(borderRadius: BorderRadius.circular(radius), child: box);
  }
}

/// Navidrome answers "no cover" with this exact image (same bytes at every size); treat it as missing.
const _placeholderLength = 69228;
const _placeholderMd5 = '83d193cefca2810f217cffd533241508';

/// Covers already resolved this session (file, or null for "the server has none"), newest last.
final _coverMemo = <String, File?>{};
void _remember(String key, File? f) {
  _coverMemo.remove(key);
  _coverMemo[key] = f;
  if (_coverMemo.length > 3000) _coverMemo.remove(_coverMemo.keys.first);
}

Future<File?> _checked(File f) async {
  final len = await f.length();
  if (len < 64) return null;
  if (len == _placeholderLength && md5.convert(await f.readAsBytes()).toString() == _placeholderMd5) return null;
  final head = await f.openRead(0, 1).first;
  if (head.isNotEmpty && head.first == 0x7B) return null; // '{': an error message, not an image
  return f;
}

/// The server's cover as a cached file, or null when the server has no real picture. A picture on the
/// phone is used as it is (covers don't change); only a missing one is fetched, and never while offline.
final _serverCoverProvider = FutureProvider.autoDispose.family<File?, (String, int)>((ref, k) async {
  final c = ref.watch(clientProvider);
  if (c == null) return null;
  final offline = ref.watch(offlineProvider);
  // the URL carries a fresh login token each time; the cache key is what identifies the picture
  final key = '${c.creds.base}|${k.$1}|${k.$2}';
  final cache = DefaultCacheManager();
  try {
    final hit = await cache.getFileFromCache(key);
    if (hit != null) {
      final f = await _checked(hit.file);
      _remember(key, f);
      return f;
    }
    if (offline) return null; // not remembered: it may be there next time we're online
    final got = await cache.downloadFile(c.coverUrl(k.$1, size: k.$2).toString(), key: key);
    final f = await _checked(got.file);
    _remember(key, f);
    return f;
  } catch (_) {
    return null; // network trouble: not remembered, so it's tried again
  }
});

class _OnlineCover extends ConsumerWidget {
  const _OnlineCover(this.kind, this.artist, this.album, this.placeholder);
  final String kind, artist, album;
  final Widget placeholder;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(onlineArtProvider((kind, artist, album))).value;
    if (url == null) return placeholder;
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }
}

/// A blurred, darkened copy of the artwork behind a header or the player.
class ArtBackdrop extends StatelessWidget {
  const ArtBackdrop({
    super.key,
    required this.cover,
    this.artist = '',
    this.album = '',
    this.height,
    this.strength = 0.55,
  });
  final String cover, artist, album;
  final double? height;
  final double strength;
  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50, tileMode: TileMode.decal),
            child: Cover(cover, size: double.infinity, radius: 0, artist: artist, album: album),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  bg.withValues(alpha: strength),
                  bg.withValues(alpha: 0.85),
                  bg,
                ],
                stops: const [0, 0.7, 1],
              ),
            ),
          ),
        ],
      ),
    );
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
    loading: () => const Center(
      child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()),
    ),
    error: (e, _) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 36, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text('$e', textAlign: TextAlign.center),
            if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    ),
  );
}

class LookupBadge extends StatelessWidget {
  const LookupBadge(this.state, {super.key, this.size = 16});
  final LookupState state;
  final double size;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color, tip) = switch (state) {
      LookupState.downloading => (Icons.hourglass_top_rounded, cs.tertiary, 'Downloading'),
      LookupState.failed => (Icons.error_outline, cs.error, 'Couldn\'t download'),
      _ => (Icons.cloud_download_outlined, cs.primary, 'Not in your library'),
    };
    return Tooltip(
      message: tip,
      child: Icon(icon, size: size, color: color),
    );
  }
}

/// One song row: cover, title, artist; taps play [list] from this song; long press / ⋮ opens the menu.
class SongTile extends ConsumerWidget {
  const SongTile(
    this.song, {
    super.key,
    this.list,
    this.index,
    this.showCover = true,
    this.showTrack = false,
    this.queueIndex,
    this.trailing,
    this.playContext,
  });
  final Song song;
  final PlayContext? playContext; // the album / playlist this list is, for smart shuffle
  final List<Song>? list;
  final int? index, queueIndex;
  final bool showCover, showTrack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(mediaItemProvider.select((m) => m.value?.id == song.id));
    // only this song's part of the download state, so a download's progress doesn't redraw every row
    final (progress, onPhone) = ref.watch(
      downloadsProvider.select((d) => (d.progress[song.id], d.files.containsKey(song.id))),
    );
    final hearted = ref.hearted(song);
    final offline = ref.watch(offlineProvider);
    final available = !offline || onPhone;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final dim = song.isLookup || !available;
    return InkWell(
      onTap: !(available || song.isLookup)
          ? null
          : () {
              if (queueIndex != null) {
                audioHandler.skipToQueueItem(queueIndex!);
              } else if (song.isLookup) {
                showSongMenu(context, ref, song);
              } else {
                final l = list ?? [song];
                audioHandler.playSongs(l, index: index ?? l.indexOf(song), context: playContext);
              }
            },
      onLongPress: () => showSongMenu(context, ref, song, queueIndex: queueIndex),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
        child: Row(
          children: [
            if (showTrack)
              SizedBox(
                width: 28,
                child: current
                    ? Icon(Icons.graphic_eq_rounded, size: 18, color: cs.primary)
                    : Text('${song.track ?? ''}', style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              )
            else if (showCover)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Opacity(
                  opacity: dim ? 0.55 : 1,
                  child: Cover(
                    song.coverArt,
                    size: 46,
                    radius: 8,
                    icon: Icons.music_note_outlined,
                    artist: song.artist,
                    album: song.album,
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (song.isLookup)
                        Padding(padding: const EdgeInsets.only(right: 6), child: LookupBadge(song.lookup, size: 15)),
                      if (queueIndex != null && audioHandler.isSuggested(song.id))
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Tooltip(
                            message: 'Smart shuffle pick',
                            child: Icon(Icons.auto_awesome, size: 15, color: cs.primary),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: current ? cs.primary : (dim ? cs.onSurfaceVariant : cs.onSurface),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (onPhone)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(Icons.arrow_circle_down_rounded, size: 14, color: cs.primary),
                        ),
                      if (hearted)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(Icons.favorite_rounded, size: 13, color: cs.primary),
                        ),
                      Expanded(
                        child: Text(
                          [
                            showTrack ? '' : song.artist,
                            formatDuration(song.duration),
                          ].where((e) => e.isNotEmpty).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            trailing ??
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (progress != null)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, value: progress > 0 ? progress : null),
                      ),
                    IconButton(
                      icon: Icon(Icons.more_vert_rounded, color: cs.onSurfaceVariant),
                      onPressed: () => showSongMenu(context, ref, song, queueIndex: queueIndex),
                    ),
                  ],
                ),
          ],
        ),
      ),
    );
  }
}

class AlbumCard extends ConsumerWidget {
  const AlbumCard(this.album, {super.key, this.width = 148, this.showArtist = true, this.showYear = false});
  final Album album;
  final double width;
  final bool showArtist, showYear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: GestureDetector(
        onTap: () => context.push('/album/${album.id}'),
        onLongPress: () => showCollectionMenu(
          context,
          ref,
          album.name,
          () async => (await ref.read(repoProvider).album(album.id)).songs,
          pin: album.isLookup
              ? null
              : LibraryPin('album', album.id, album.name, cover: album.coverArt, subtitle: 'Album · ${album.artist}'),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Cover(
                    album.coverArt,
                    size: double.infinity,
                    radius: 14,
                    artist: album.artist,
                    album: album.name,
                  ),
                ),
                if (album.isLookup)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(color: cs.surface.withValues(alpha: 0.85), shape: BoxShape.circle),
                      child: LookupBadge(album.lookup),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
            if (showArtist || showYear)
              Text(
                [if (showArtist) album.artist, if (showYear && album.year != null) '${album.year}'].join(' · '),
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

/// A titled horizontal row (home, artist pages, discover).
class Shelf extends StatelessWidget {
  const Shelf({super.key, required this.title, required this.children, this.onMore, this.height = 206, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final VoidCallback? onMore;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title, subtitle: subtitle, onMore: onMore),
        SizedBox(
          height: height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: children.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (_, i) => children[i],
          ),
        ),
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing, this.subtitle, this.onMore});
  final String text;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onMore;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3)),
                if (subtitle != null)
                  Text(subtitle!, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          ?trailing,
          if (onMore != null) TextButton(onPressed: onMore, child: const Text('See all')),
        ],
      ),
    );
  }
}

/// The floating bar above the navigation: what's playing, progress, play/pause. Tap opens the player.
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
    final t = Theme.of(context).textTheme;
    final loading =
        state?.processingState == AudioProcessingState.loading ||
        state?.processingState == AudioProcessingState.buffering;
    final frac = pos == null || pos.duration.inMilliseconds == 0
        ? 0.0
        : (pos.position.inMilliseconds / pos.duration.inMilliseconds).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/player'),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                child: Row(
                  children: [
                    Hero(
                      tag: 'cover',
                      child: Cover(
                        song?.coverArt ?? '',
                        size: 42,
                        radius: 8,
                        icon: Icons.music_note_outlined,
                        artist: song?.artist ?? '',
                        album: song?.album ?? '',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragEnd: (d) {
                          final v = d.primaryVelocity ?? 0;
                          if (v < -300) audioHandler.skipToNext();
                          if (v > 300) audioHandler.skipToPrevious();
                        },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
                            Text(
                              item.artist ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (song != null && !isPodcastId(song.id))
                      IconButton(
                        icon: Icon(
                          song.starred ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          color: song.starred ? cs.primary : null,
                        ),
                        onPressed: () => toggleStarSong(context, ref, song),
                      ),
                    loading
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                          )
                        : IconButton(
                            iconSize: 30,
                            icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                            onPressed: playing ? audioHandler.pause : audioHandler.play,
                          ),
                  ],
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: frac,
                    minHeight: 2,
                    backgroundColor: cs.onSurface.withValues(alpha: 0.08),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Round play button, shuffle, and optional extras, for album / playlist / artist pages.
/// [source] names the page's songs (the same key given to playSongs): while they're what's playing, the
/// button shows pause and pauses / resumes instead of starting over.
class PlayButtons extends ConsumerWidget {
  const PlayButtons({
    super.key,
    required this.onPlay,
    required this.onShuffle,
    this.source,
    this.extra = const [],
    this.leading = const [],
  });
  final VoidCallback onPlay, onShuffle;
  final String? source;
  final List<Widget> extra, leading;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(playbackStateProvider.select((s) => s.value?.playing ?? false));
    ref.watch(queueProvider);
    final ours = source != null && audioHandler.playSource == source && audioHandler.songs.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
      child: Row(
        children: [
          ...leading,
          ...extra,
          const Spacer(),
          IconButton(iconSize: 26, tooltip: 'Shuffle', icon: const Icon(Icons.shuffle_rounded), onPressed: onShuffle),
          const SizedBox(width: 8),
          SizedBox(
            width: 56,
            height: 56,
            child: FilledButton(
              style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
              onPressed: !ours
                  ? onPlay
                  : playing
                  ? audioHandler.pause
                  : audioHandler.play,
              child: Icon(ours && playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 32),
            ),
          ),
        ],
      ),
    );
  }
}

/// Spotify-style download switch for a whole collection: keeps it on the phone, new songs included.
class DownloadToggle extends ConsumerWidget {
  const DownloadToggle({super.key, required this.pinKey, required this.songs});
  final String pinKey;
  final Future<List<Song>> Function() songs;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.watch(downloadsProvider);
    final on = dl.pins.contains(pinKey);
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: on ? 'Downloaded (tap to remove)' : 'Download',
      iconSize: 28,
      icon: Icon(
        on ? Icons.arrow_circle_down_rounded : Icons.arrow_circle_down_outlined,
        color: on ? cs.primary : null,
      ),
      onPressed: () async {
        final n = ref.read(downloadsProvider.notifier);
        final list = (await songs()).where((s) => !s.isLookup).toList();
        if (on) {
          if (context.mounted &&
              await confirm(
                context,
                'Remove download?',
                'These songs stay on your server; they just leave the phone.',
                ok: 'Remove',
              )) {
            await n.unpin(pinKey, list);
          }
        } else {
          await n.pin(pinKey, list);
          if (context.mounted) toast(context, 'Downloading ${nSongs(list.length)}, and new ones as they\'re added');
        }
      },
    );
  }
}

/// "1 song" / "12 songs".
String nSongs(int n) => n == 1 ? '1 song' : '$n songs';

/// Encore's logo: a record whose label is a lowercase "e". Drawn in code, so it's sharp at any size
/// (the same geometry as the launcher icon: record r 29.5, grooves every 3, label r 17.5, e r 9.5).
class EncoreLogo extends StatelessWidget {
  const EncoreLogo({super.key, this.size = 64});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: CustomPaint(painter: _LogoPainter()));
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 59; // the record (diameter 59) fills the box
    final c = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: c, radius: 29.5 * s);
    final gradient = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFDCE3FF), Color(0xFF7C90FF)],
    ).createShader(rect);
    const ink = Color(0xFF0D0E15);
    canvas.drawCircle(c, 29.5 * s, Paint()..shader = gradient);
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 * s
      ..color = ink.withValues(alpha: 0.22);
    for (final r in [26.5, 23.5, 20.5]) {
      canvas.drawCircle(c, r * s, groove);
    }
    canvas.drawCircle(c, 17.5 * s, Paint()..color = ink);
    final e = Path()
      ..moveTo(c.dx - 9.5 * s, c.dy)
      ..lineTo(c.dx + 9.5 * s, c.dy)
      ..arcTo(Rect.fromCircle(center: c, radius: 9.5 * s), 0, -(2 * 3.141592653589793 - 3.141592653589793 / 4), false);
    canvas.drawPath(
      e,
      Paint()
        ..shader = gradient
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.6 * s
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_LogoPainter oldDelegate) => false;
}

/// A scrolling page: [header] widgets, then [count] rows built only as they scroll into view (so a playlist
/// of thousands of songs opens instantly), then [footer].
class LazyListView extends StatelessWidget {
  const LazyListView({
    super.key,
    this.header = const [],
    required this.count,
    required this.itemBuilder,
    this.footer = const [],
    this.padding,
  });
  final List<Widget> header, footer;
  final int count;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: padding,
    itemCount: header.length + count + footer.length,
    itemBuilder: (ctx, i) {
      if (i < header.length) return header[i];
      i -= header.length;
      if (i < count) return itemBuilder(ctx, i);
      return footer[i - count];
    },
  );
}
