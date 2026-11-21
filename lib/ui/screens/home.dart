import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/appearance.dart';
import '../../core/settings.dart';
import '../../data/ai.dart';
import '../../data/jam.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../data/playlist_covers.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../state.dart';
import '../widgets.dart';
import 'podcasts.dart';
import 'following.dart';
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
                          child: Icon(Icons.cloud_off_rounded, color: cs.onSurfaceVariant, size: 20),
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
              for (final s in sections)
                SliverToBoxAdapter(
                  child: switch (s) {
                    'playlists' => const _PlaylistShelf(),
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

class _QuickPills extends ConsumerWidget {
  const _QuickPills();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(repoProvider).online;
    Widget pill(IconData icon, String label, Future<void> Function() go) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: Icon(icon, size: 18),
        label: Text(label),
        onPressed: () async {
          try {
            await go();
          } catch (e) {
            if (context.mounted) toast(context, '$e');
          }
        },
      ),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          pill(
            Icons.shuffle_rounded,
            'Shuffle all',
            () async => audioHandler.playSongs(await ref.read(repoProvider).randomSongs(size: 200)),
          ),
          pill(Icons.favorite_rounded, 'Liked songs', () async => context.push('/liked')),
          if (online)
            pill(Icons.auto_awesome, 'Made for you', () async {
              final ai = ref.read(aiProvider);
              if (ai == null) {
                toast(context, 'Made for you needs AudioMuse-AI on the server');
                return;
              }
              toast(context, 'Making your mix…');
              final songs = await ai.forYou();
              if (songs.isEmpty) {
                if (context.mounted) toast(context, 'Not enough listening history yet');
                return;
              }
              await audioHandler.playSongs(songs, source: 'ai:Made for you');
            }),
          if (online) pill(Icons.insights_rounded, 'Your stats', () async => context.push('/stats')),
          if (online)
            pill(
              Icons.groups_rounded,
              ref.watch(jamProvider).active ? 'Jam is on' : 'Start a Jam',
              () => showJamSheet(context),
            ),
          if (online)
            pill(Icons.devices_rounded, 'Continue from another device', () async {
              final ok = await audioHandler.loadServerQueue();
              if (context.mounted) toast(context, ok ? 'Queue loaded. Press play.' : 'No saved queue on the server');
            }),
        ],
      ),
    );
  }
}

/// Six recently played albums as compact tiles, two columns.
class _JumpBackIn extends ConsumerWidget {
  const _JumpBackIn();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums =
        ref.watch(albumListProvider('recent')).value?.where((a) => !a.isLookup).take(MediaQuery.sizeOf(context).width >= 900 ? 9 : 6).toList() ?? const <Album>[];
    if (albums.isEmpty) return const SizedBox(height: 8);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: GridView.count(
        crossAxisCount: MediaQuery.sizeOf(context).width >= 900 ? 3 : 2, // wider screens: three across
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 3.1,
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
