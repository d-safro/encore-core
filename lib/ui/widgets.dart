import 'dart:io';
import '../desktop/drag.dart';
import '../core/platform.dart';
import 'dart:ui';

import 'package:crypto/crypto.dart';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/appearance.dart';
import '../core/settings.dart';
import '../data/account.dart';
import '../data/cover_cache.dart';
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
    if (coverArt.startsWith('file:')) {
      // your own playlist picture, kept on the phone
      img = Image.file(
        File(coverArt.substring(5)),
        fit: BoxFit.cover,
        width: fill ? null : side,
        height: fill ? null : side,
        cacheWidth: px,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else if (coverArt.isEmpty || c == null) {
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
    if (circle) return ClipOval(child: box);
    return ClipRRect(borderRadius: BorderRadius.circular(AppLook.of(context).r(radius)), child: box);
  }
}

const _placeholderLength = noCoverLength; // Navidrome's "no cover" image (cover_cache.dart)
const _placeholderMd5 = noCoverMd5;

/// Covers already resolved this session (file, or null for "the server has none"), newest last.
final _coverMemo = <String, File?>{};

/// After the picture cache is emptied.
void forgetCovers() => _coverMemo.clear();
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
  final cache = coverCache;
  try {
    final hit = await cache.getFileFromCache(key);
    if (hit != null) {
      final f = await _checked(hit.file);
      // a real picture is kept as it is. Navidrome's "no picture" is asked about again after 6 hours, and
      // anything else (an error the server sent while it had trouble) right away: one bad moment mustn't
      // hide a cover for good.
      final noCover = f == null && await hit.file.length() == _placeholderLength;
      final fresh = DateTime.now().difference(await hit.file.lastModified()) < const Duration(hours: 6);
      if (f != null || (noCover && fresh) || offline) {
        if (!offline || f != null) _remember(key, f);
        return f;
      }
      await cache.removeFile(key);
    }
    if (offline) return null; // not remembered: it may be there next time we're online
    final got = await cache.downloadFile(c.coverUrl(k.$1, size: k.$2).toString(), key: key);
    final f = await _checked(got.file);
    if (f == null && (await got.file.length()) != _placeholderLength) {
      await cache.removeFile(key); // an error message, not Navidrome's "no cover": try again next time
      return null;
    }
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
      cacheManager: coverCache,
      fit: BoxFit.cover,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }
}

/// A page's name that fades into the top bar once its header has scrolled away.
class ScrollTitle {
  final shown = ValueNotifier(false);
  Widget title(String text) => ValueListenableBuilder<bool>(
    valueListenable: shown,
    builder: (_, v, _) => AnimatedOpacity(
      opacity: v ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );
  Widget wrap(Widget body) => NotificationListener<ScrollUpdateNotification>(
    onNotification: (n) {
      if (n.depth == 0) shown.value = n.metrics.pixels > 280;
      return false;
    },
    child: body,
  );
}

/// For pages whose header art runs under the app bar: see-through at the top, solid once the list is
/// scrolled under it (so the back button never floats over song titles).
WidgetStateColor overArtBar(BuildContext context) {
  final c = Theme.of(context).colorScheme.surfaceContainer;
  return WidgetStateColor.resolveWith((s) => s.contains(WidgetState.scrolledUnder) ? c : Colors.transparent);
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
      LookupState.downloading => (Icons.hourglass_top_rounded, cs.tertiary, 'Your server is getting it'),
      LookupState.failed => (Icons.error_outline, cs.error, 'No copy found'),
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
    final compact = AppLook.of(context).compact;
    Widget tile = InkWell(
      onTap: !(available || song.isLookup)
          ? null
          : () {
              if (queueIndex != null) {
                audioHandler.skipToQueueItem(queueIndex!);
              } else if (song.isLookup && !audioHandler.autoGet) {
                showSongMenu(context, ref, song); // ask first (the setting is off)
              } else {
                // a song you don't have plays from its list when the list has it, else on its own
                final l = list != null && list!.contains(song) ? list! : [song];
                audioHandler.playSongs(l, index: index != null && l.length > 1 ? index! : l.indexOf(song), context: playContext);
              }
            },
      onSecondaryTap: () => showSongMenu(context, ref, song, queueIndex: queueIndex),
      onLongPress: () => showSongMenu(context, ref, song, queueIndex: queueIndex),
      // desktop, a wide list: a table row (title and artist, album, length); else the phone's row
      child: LayoutBuilder(
        builder: (context, box) => isDesktop && queueIndex == null && trailing == null && box.maxWidth >= 760
            ? _WideSongRow(song: song, current: current, dim: dim, showTrack: showTrack, showCover: showCover,
                hearted: hearted, progress: progress, onPhone: onPhone, queueIndex: queueIndex)
            : Padding(
        padding: EdgeInsets.fromLTRB(16, compact ? 2 : 6, 4, compact ? 2 : 6),
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
                    size: compact ? 38 : 46,
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
      ),
    );
    // desktop: drag songs onto the queue, Liked songs or a playlist in the sidebar
    if (isDesktop && queueIndex == null && !song.isLookup) tile = songDragSource(songs: [song], child: tile);
    return tile;
  }
}

class AlbumCard extends ConsumerWidget {
  const AlbumCard(this.album, {super.key, this.width, this.showArtist = true, this.showYear = false});
  final Album album;
  final double? width; // default: the card size picked in Settings → Appearance
  final bool showArtist, showYear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: width ?? AppLook.of(context).cardWidth,
      child: GestureDetector(
        onTap: () => context.push('/album/${album.id}'),
        onSecondaryTap: () => showCollectionMenu(
          context,
          ref,
          album.name,
          () async => (await ref.read(repoProvider).album(album.id)).songs,
          pin: album.isLookup
              ? null
              : LibraryPin('album', album.id, album.name, cover: album.coverArt, subtitle: 'Album · ${album.artist}'),
        ),
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
                // desktop: a play button on hover, like a desktop music app
                if (isDesktop && !album.isLookup)
                  Positioned.fill(
                    child: HoverPlay(
                      onPlay: () async {
                        final songs = (await ref.read(repoProvider).album(album.id)).songs;
                        await audioHandler.playSongs(
                          songs,
                          context: PlayContext.album(album.id, album.name),
                          source: 'album:${album.id}',
                        );
                      },
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
class Shelf extends StatefulWidget {
  const Shelf({
    super.key,
    required this.title,
    required this.children,
    this.onMore,
    this.height,
    this.textHeight = 58,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final VoidCallback? onMore;
  final double? height; // default: fits an album card of the chosen size plus [textHeight] for its lines
  final double textHeight;

  @override
  State<Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<Shelf> {
  final _ctl = ScrollController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  /// Desktop: ‹ › page the row (a mouse wheel scrolls the page, not the row).
  void _page(int dir) {
    if (!_ctl.hasClients) return;
    final p = _ctl.position;
    _ctl.animateTo(
      (p.pixels + dir * p.viewportDimension * 0.8).clamp(0.0, p.maxScrollExtent),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    Widget list = ListView.separated(
      controller: _ctl,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: widget.children.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (_, i) => widget.children[i],
    );
    if (isDesktop) {
      // the row can also be dragged with the mouse
      list = ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {PointerDeviceKind.mouse, PointerDeviceKind.touch, PointerDeviceKind.trackpad},
          scrollbars: false,
        ),
        child: list,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          widget.title,
          subtitle: widget.subtitle,
          onMore: widget.onMore,
          trailing: isDesktop
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.chevron_left_rounded),
                      onPressed: () => _page(-1),
                    ),
                    IconButton(
                      tooltip: 'More',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.chevron_right_rounded),
                      onPressed: () => _page(1),
                    ),
                  ],
                )
              : null,
        ),
        SizedBox(height: widget.height ?? AppLook.of(context).cardWidth + widget.textHeight, child: list),
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
    final look = AppLook.of(context);
    final style = look.miniPlayer;
    final flat = style == MiniPlayerStyle.flat;
    final slim = style == MiniPlayerStyle.slim;
    final progress = LinearProgressIndicator(
      value: frac,
      minHeight: 2,
      backgroundColor: cs.onSurface.withValues(alpha: 0.08),
    );
    final bar = Material(
      // flat: a full-width strip that sits on the tabs; else a floating card
      color: flat ? cs.surfaceContainer : cs.surfaceContainerHigh,
      borderRadius: flat ? null : BorderRadius.circular(look.r(slim ? 12 : 16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/player'),
        child: Stack(
          children: [
            Padding(
              padding: slim ? const EdgeInsets.fromLTRB(6, 4, 2, 4) : EdgeInsets.fromLTRB(flat ? 12 : 8, 8, 4, 8),
              child: Row(
                children: [
                  Hero(
                    tag: 'cover',
                    child: Cover(
                      song?.coverArt ?? '',
                      size: slim ? 34 : 42,
                      radius: slim ? 6 : 8,
                      icon: Icons.music_note_outlined,
                      artist: song?.artist ?? '',
                      album: song?.album ?? '',
                    ),
                  ),
                  SizedBox(width: slim ? 10 : 12),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragEnd: (d) {
                        final v = d.primaryVelocity ?? 0;
                        if (v < -300) audioHandler.skipToNext();
                        if (v > 300) audioHandler.skipToPrevious();
                      },
                      child: slim
                          // slim: title and artist on one line
                          ? Text.rich(
                              TextSpan(
                                text: item.title,
                                style: t.titleSmall,
                                children: [
                                  if ((item.artist ?? '').isNotEmpty)
                                    TextSpan(
                                      text: '  ·  ${item.artist}',
                                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                    ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : Column(
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
                  if (!slim && song != null && !isPodcastId(song.id))
                    IconButton(
                      icon: Icon(
                        song.starred ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: song.starred ? cs.primary : null,
                      ),
                      onPressed: () => toggleStarSong(context, ref, song),
                    ),
                  loading
                      ? Padding(
                          padding: EdgeInsets.all(slim ? 9 : 12),
                          child: const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        )
                      : IconButton(
                          iconSize: slim ? 26 : 30,
                          visualDensity: slim ? VisualDensity.compact : null,
                          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                          onPressed: playing ? audioHandler.pause : audioHandler.play,
                        ),
                ],
              ),
            ),
            if (flat)
              Positioned(left: 0, right: 0, top: 0, child: progress)
            else
              Positioned(
                left: 12,
                right: 12,
                bottom: 0,
                child: ClipRRect(borderRadius: BorderRadius.circular(2), child: progress),
              ),
          ],
        ),
      ),
    );
    if (flat) return bar;
    return Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 6), child: bar);
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
                'These songs stay on your server; they just leave the $deviceWord.',
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
String nSongs(int n) => plural(n, 'song');

/// "1 album" / "3 albums" (or [many] when it isn't just an s).
String plural(int n, String one, [String? many]) => n == 1 ? '1 $one' : '$n ${many ?? '${one}s'}';

/// Encore's logo: a record whose label is a lowercase "e". Drawn in code, so it's sharp at any size
/// (the same geometry as the launcher icon: record r 29.5, grooves every 3, label r 17.5, e r 9.5).
class EncoreLogo extends StatelessWidget {
  const EncoreLogo({super.key, this.size = 64});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _LogoPainter()),
  );
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
    // the handwritten e (docs/logo.svg), measured from the centre
    double p(double x) => c.dx + x * s;
    double q(double y) => c.dy + y * s;
    final e = Path()
      ..moveTo(p(-9.49), q(4.55))
      ..cubicTo(p(-4.54), q(4.01), p(2.48), q(1.3), p(5.0), q(-2.65))
      ..cubicTo(p(6.8), q(-5.53), p(5.0), q(-8.33), p(1.76), q(-8.14))
      ..cubicTo(p(-2.2), q(-7.88), p(-5.09), q(-3.2), p(-4.9), q(1.3))
      ..cubicTo(p(-4.73), q(5.8), p(-1.48), q(8.33), p(2.3), q(8.15))
      ..cubicTo(p(5.17), q(7.97), p(7.7), q(6.35), p(9.49), q(4.01));
    canvas.drawPath(
      e,
      Paint()
        ..shader = gradient
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.9 * s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
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

/// Desktop: a round play button that shows in the corner while the mouse is over [child]'s area.
class HoverPlay extends StatefulWidget {
  const HoverPlay({super.key, required this.onPlay});
  final Future<void> Function() onPlay;
  @override
  State<HoverPlay> createState() => _HoverPlayState();
}

class _HoverPlayState extends State<HoverPlay> {
  bool _hover = false, _busy = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Align(
        alignment: Alignment.bottomRight,
        child: AnimatedOpacity(
          opacity: _hover || _busy ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: IgnorePointer(
              ignoring: !_hover && !_busy,
              child: FloatingActionButton.small(
                heroTag: null,
                elevation: 2,
                tooltip: 'Play',
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
                shape: const CircleBorder(),
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        try {
                          await widget.onPlay();
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                child: _busy
                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
                    : const Icon(Icons.play_arrow_rounded),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A song as a table row on a wide desktop list: number or cover, title and artist, album, heart, length, menu.
class _WideSongRow extends ConsumerStatefulWidget {
  const _WideSongRow({
    required this.song,
    required this.current,
    required this.dim,
    required this.showTrack,
    required this.showCover,
    required this.hearted,
    required this.progress,
    required this.onPhone,
    required this.queueIndex,
  });
  final Song song;
  final bool current, dim, showTrack, showCover, hearted, onPhone;
  final double? progress;
  final int? queueIndex;

  @override
  ConsumerState<_WideSongRow> createState() => _WideSongRowState();
}

class _WideSongRowState extends ConsumerState<_WideSongRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.song;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final sub = t.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          children: [
            if (widget.showTrack)
              SizedBox(
                width: 32,
                child: widget.current
                    ? Icon(Icons.graphic_eq_rounded, size: 18, color: cs.primary)
                    : Text('${s.track ?? ''}', style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              )
            else if (widget.showCover)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Opacity(
                  opacity: widget.dim ? 0.55 : 1,
                  child: Cover(s.coverArt, size: 40, radius: 6, icon: Icons.music_note_outlined, artist: s.artist, album: s.album),
                ),
              ),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: widget.current ? cs.primary : (widget.dim ? cs.onSurfaceVariant : cs.onSurface),
                    ),
                  ),
                  Row(
                    children: [
                      if (widget.onPhone)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(Icons.arrow_circle_down_rounded, size: 14, color: cs.primary),
                        ),
                      Flexible(
                        child: GestureDetector(
                          onTap: s.artistId.isEmpty ? null : () => context.push('/artist/${s.artistId}'),
                          child: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: sub),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (!widget.showTrack)
              Expanded(
                flex: 4,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: GestureDetector(
                    onTap: s.albumId.isEmpty ? null : () => context.push('/album/${s.albumId}'),
                    child: Text(s.album, maxLines: 1, overflow: TextOverflow.ellipsis, style: sub),
                  ),
                ),
              ),
            // the heart: always when liked, else only under the mouse
            SizedBox(
              width: 40,
              child: widget.hearted || _hover
                  ? IconButton(
                      tooltip: widget.hearted ? 'Unlike' : 'Like',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        widget.hearted ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: widget.hearted ? cs.primary : cs.onSurfaceVariant,
                      ),
                      onPressed: s.isLookup && !audioHandler.autoGet ? null : () => toggleStarSong(context, ref, s),
                    )
                  : null,
            ),
            SizedBox(
              width: 52,
              child: Text(formatDuration(s.duration), textAlign: TextAlign.right, style: sub),
            ),
            SizedBox(
              width: 44,
              child: widget.progress != null
                  ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(
                      tooltip: 'More',
                      icon: Icon(Icons.more_horiz_rounded, color: cs.onSurfaceVariant),
                      onPressed: () => showSongMenu(context, ref, s, queueIndex: widget.queueIndex),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
