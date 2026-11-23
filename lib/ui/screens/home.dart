import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/appearance.dart';
import '../../core/platform.dart';
import '../../core/settings.dart';
import '../../data/ai.dart';
import '../../data/jam.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../data/playlist_covers.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../state.dart';
import '../../data/concerts.dart';
import '../widgets.dart';
import 'podcasts.dart';
import 'following.dart';
import '../../data/mixes.dart';
import 'concerts.dart';
import 'jam.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const titles = {
    'recent': 'Recently played',
    'newest': 'Recently added',
    'frequent': 'Most played',
    'starred': 'Favourite albums',
    'random': 'Something different',
    'highest': 'Top rated',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final set = ref.watch(settingsProvider);
    final sections = set.homeSections;
    final offline = ref.watch(offlineProvider);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          for (final k in titles.keys) {
            ref.invalidate(albumListProvider(k));
          }
          ref.invalidate(playlistsProvider);
          ref.invalidate(mixesProvider);
          ref.invalidate(concertsProvider);
        },
        child: SafeArea(
          bottom: false,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, set.showGreeting ? 20 : 4, 8, set.showGreeting ? 4 : 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: set.showGreeting
                            ? Text(
                                _greeting(),
                                style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.8),
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (offline)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Tooltip(
                            message: 'Offline: your downloads play',
                            child: Icon(Icons.cloud_off_rounded, color: cs.onSurfaceVariant, size: 20),
                          ),
                        ),
                      IconButton(
                        icon: const Icon(Icons.download_done_rounded),
                        tooltip: 'Downloads',
                        onPressed: () => context.push('/downloads'),
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings_outlined),
                        tooltip: 'Settings',
                        onPressed: () => context.push('/settings'),
                      ),
                    ],
                  ),
                ),
              ),
              if (set.showQuickPills) const SliverToBoxAdapter(child: _QuickPills()),
              if (set.showJumpBackIn) const SliverToBoxAdapter(child: _JumpBackIn()),
              const SliverToBoxAdapter(child: NewEpisodesShelf()),
              const SliverToBoxAdapter(child: NewReleasesShelf()),
              const SliverToBoxAdapter(child: ConcertsShelf()),
              for (final s in sections)
                SliverToBoxAdapter(
                  child: switch (s) {
                    'playlists' => const _PlaylistShelf(),
                    'yourMixes' => const MixesShelf(),
                    'recent' => const SizedBox.shrink(), // shown as "Jump back in" above
                    _ when titles.containsKey(s) => _AlbumShelf(type: s, title: titles[s]!),
                    _ => const SizedBox.shrink(),
                  },
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
        ),
      ),
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    return h < 5
        ? 'Good night'
        : h < 12
        ? 'Good morning'
        : h < 18
        ? 'Good afternoon'
        : 'Good evening';
  }
}

/// Shortcuts under the greeting (Shuffle all, Liked songs, Made for you…): a grid of tiles, two across on a
/// phone and more on wider screens, so they all show without scrolling sideways.
class _QuickPills extends ConsumerWidget {
  const _QuickPills();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(repoProvider).online;
    final jamOn = online && ref.watch(jamProvider).active;
    // (icon, label, what a screen reader and the tooltip say, action)
    final items = <(IconData, String, String, Future<void> Function())>[
      (
        Icons.shuffle_rounded,
        'Shuffle all',
        'Shuffle all',
        () async => audioHandler.playSongs(await ref.read(repoProvider).randomSongs(size: 200)),
      ),
      (Icons.favorite_rounded, 'Liked songs', 'Liked songs', () async => context.push('/liked')),
      if (online)
        (Icons.auto_awesome, 'Made for you', 'Made for you', () async {
          if (!await ref.read(aiOfferedProvider.future) && !await ref.read(forYouOfferedProvider.future)) {
            if (context.mounted) toast(context, 'Made for you needs AudioMuse-AI, or Conductor 0.6 or newer, on the server');
            return;
          }
          if (!context.mounted) return;
          toast(context, 'Making your mix…');
          final songs = await madeForYou(ref);
          if (songs.isEmpty) {
            if (context.mounted) toast(context, 'Not enough listening history yet');
            return;
          }
          await audioHandler.playSongs(songs, source: 'ai:Made for you');
        }),
      if (online) (Icons.insights_rounded, 'Your stats', 'Your stats', () async => context.push('/stats')),
      if (online)
        (
          Icons.groups_rounded,
          jamOn ? 'Ensemble is on' : 'Ensemble',
          jamOn ? 'Ensemble is on' : 'Ensemble · Listen together',
          () async => showJamSheet(context),
        ),
      if (online)
        (Icons.devices_rounded, 'Continue here', 'Continue from another device', () async {
          final ok = await audioHandler.loadServerQueue();
          if (context.mounted) toast(context, ok ? 'Queue loaded. Press play.' : 'No saved queue on the server');
        }),
    ];
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final look = AppLook.of(context);
    Widget tile((IconData, String, String, Future<void> Function()) it) {
      final (icon, label, full, go) = it;
      return Semantics(
        button: true,
        label: full,
        excludeSemantics: true,
        child: Tooltip(
          message: full,
          child: Material(
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(look.r(10)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () async {
                try {
                  await go();
                } catch (e) {
                  if (context.mounted) toast(context, '$e');
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(look.r(8)),
                      ),
                      child: Icon(icon, size: 18, color: cs.primary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 2, // a narrow tile wraps "Continue here" rather than cutting it off
                        overflow: TextOverflow.ellipsis,
                        style: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, height: 1.15),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: LayoutBuilder(
        builder: (context, box) {
          // a phone: two across; wider: three; a wide desktop window: all six in one row
          final columns = box.maxWidth >= 900 ? 6 : (box.maxWidth >= 560 ? 3 : 2);
          return GridView(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              mainAxisExtent: 52,
            ),
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [for (final it in items) tile(it)],
          );
        },
      ),
    );
  }
}

/// Six recently played albums as compact tiles, two columns.
class _JumpBackIn extends ConsumerWidget {
  const _JumpBackIn();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(albumListProvider('recent')).value?.where((a) => !a.isLookup) ?? const <Album>[];
    if (recent.isEmpty) return const SizedBox(height: 8);
    if (!isDesktop) {
      final wide = MediaQuery.sizeOf(context).width >= 900; // wider screens: three across
      return _grid(context, ref, recent.take(wide ? 9 : 6).toList(), columns: wide ? 3 : 2);
    }
    // desktop: rows of a fixed height, more across as the page widens (tiles that kept the phone's shape grew
    // to 170 px tall on a big window); two or three full rows
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 1200 ? 4 : (box.maxWidth >= 640 ? 3 : 2);
        return _grid(context, ref, recent.take(columns == 4 ? 8 : columns * 3).toList(), columns: columns, height: 72);
      },
    );
  }

  Widget _grid(BuildContext context, WidgetRef ref, List<Album> albums, {required int columns, double? height}) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: GridView(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 3.1,
          mainAxisExtent: height,
        ),
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final a in albums)
            Material(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppLook.of(context).r(10)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => context.push('/album/${a.id}'),
                onSecondaryTap: () => showCollectionMenu(
                  context,
                  ref,
                  a.name,
                  () async => (await ref.read(repoProvider).album(a.id)).songs,
                ),
                onLongPress: () => showCollectionMenu(
                  context,
                  ref,
                  a.name,
                  () async => (await ref.read(repoProvider).album(a.id)).songs,
                ),
                child: Row(
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: Cover(a.coverArt, size: double.infinity, radius: 0, artist: a.artist, album: a.name),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        a.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AlbumShelf extends ConsumerWidget {
  const _AlbumShelf({required this.type, required this.title});
  final String type, title;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(albumListProvider(type));
    return albums.when(
      data: (list) => Shelf(
        title: title,
        onMore: () => context.push('/albums/$type?title=${Uri.encodeComponent(title)}'),
        children: [for (final a in list.where((a) => !a.isLookup)) AlbumCard(a)],
      ),
      loading: () => const SizedBox(height: 60),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

/// Your mixes (made by the server): Discover Weekly, Release Radar, Daily Mix 1–6, Daylist.
class MixesShelf extends ConsumerWidget {
  const MixesShelf({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(mixesProvider).value;
    if (m == null || !m.supported || m.mixes.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Shelf(
      title: 'Repertoire',
      subtitle: 'Your mixes',
      children: [
        for (final x in m.mixes)
          SizedBox(
            width: AppLook.of(context).cardWidth,
            child: Tappable(
              onTap: () => context.push('/playlist/${x.playlistId}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(aspectRatio: 1, child: MixCover(x)),
                  const SizedBox(height: 8),
                  Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
                  Text(
                    x.comment.isEmpty ? nSongs(x.songCount) : x.comment,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A mix's picture: the playlist's covers with its name over a band of colour (each kind its own colour).
class MixCover extends StatelessWidget {
  const MixCover(this.mix, {super.key});
  final Mix mix;

  static Color colorOf(String kind, String name) => switch (kind) {
    'discover' => const Color(0xFF3D5AFE),
    'radar' => const Color(0xFF00BFA5),
    'daylist' => const Color(0xFFFF6E40),
    _ => HSVColor.fromAHSV(1, (name.hashCode % 360).toDouble().abs(), 0.6, 0.75).toColor(),
  };

  @override
  Widget build(BuildContext context) {
    final c = colorOf(mix.kind, mix.name);
    final title = mix.kind == 'daylist' ? 'daylist' : mix.name;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Cover('pl-${mix.playlistId}', size: double.infinity, radius: 0, icon: Icons.queue_music_rounded),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                // the band under the name is a little darker than the colour, so the white name stays readable
                // over light covers and in the light theme
                colors: [c.withValues(alpha: 0.15), Color.lerp(c, Colors.black, 0.3)!.withValues(alpha: 0.95)],
                stops: const [0.35, 1],
              ),
            ),
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 18,
                height: 1.05,
                shadows: [Shadow(color: Colors.black45, blurRadius: 6)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistShelf extends ConsumerWidget {
  const _PlaylistShelf();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lists = ref.watch(playlistsProvider);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return lists.when(
      data: (l) => Shelf(
        title: 'Your playlists',
        onMore: () => context.go('/library?tab=0'),
        children: [
          for (final p in l)
            SizedBox(
              width: AppLook.of(context).cardWidth,
              child: Tappable(
                onTap: () => context.push('/playlist/${p.id}'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: Cover(
                        shownPlaylistCover(ref.watch(playlistCoversProvider)[p.id], p.coverArt),
                        size: double.infinity,
                        radius: 14,
                        icon: Icons.queue_music_rounded,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
                    Text(nSongs(p.songCount ?? 0), style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
        ],
      ),
      loading: () => const SizedBox(height: 60),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}
