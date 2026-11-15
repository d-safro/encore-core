import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/settings.dart';
import '../../data/library.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../state.dart';
import '../widgets.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const titles = {
    'recent': 'Recently played',
    'newest': 'Recently added',
    'frequent': 'Most played',
    'starred': 'Favourite albums',
    'random': 'Discover',
    'highest': 'Top rated',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(settingsProvider.select((s) => s.homeSections));
    final offline = ref.watch(offlineProvider);
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          for (final t in titles.keys) {
            ref.invalidate(albumListProvider(t));
          }
          ref.invalidate(playlistsProvider);
        },
        child: CustomScrollView(slivers: [
          SliverAppBar.large(
            title: Text(_greeting()),
            actions: [
              if (offline)
                const Padding(padding: EdgeInsets.only(right: 8), child: Chip(avatar: Icon(Icons.cloud_off, size: 16), label: Text('Offline'))),
              IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => context.push('/settings')),
            ],
          ),
          SliverToBoxAdapter(child: _QuickMixes()),
          for (final s in sections)
            SliverToBoxAdapter(
              child: switch (s) {
                'playlists' => const _PlaylistShelf(),
                'mixes' => const SizedBox.shrink(),
                _ when titles.containsKey(s) => _AlbumShelf(type: s, title: titles[s]!),
                _ => const SizedBox.shrink(),
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ]),
      ),
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    return h < 5 ? 'Good night' : h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
  }
}

class _QuickMixes extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(repoProvider).online;
    Widget chip(IconData icon, String label, Future<void> Function() go) => Padding(
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        chip(Icons.shuffle, 'Shuffle all', () async => audioHandler.playSongs(await ref.read(repoProvider).randomSongs(size: 200))),
        chip(Icons.favorite, 'Favourites', () async {
          final r = await ref.read(repoProvider).starred();
          await audioHandler.playSongs(r.songs, shuffle: true);
        }),
        if (online)
          chip(Icons.cloud_sync_outlined, 'Continue from other device', () async {
            final ok = await audioHandler.loadServerQueue();
            if (context.mounted) toast(context, ok ? 'Queue loaded — press play' : 'No saved queue on the server');
          }),
        chip(Icons.offline_pin_outlined, 'Downloaded', () async => context.push('/downloads')),
      ]),
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
    return lists.when(
      data: (l) => Shelf(
        title: 'Playlists',
        onMore: () => context.go('/library?tab=3'),
        children: [
          for (final p in l)
            SizedBox(
              width: 150,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => context.push('/playlist/${p.id}'),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    AspectRatio(aspectRatio: 1, child: Cover(p.coverArt, size: double.infinity, radius: 10, icon: Icons.queue_music)),
                    const SizedBox(height: 6),
                    Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                    Text('${p.songCount ?? 0} songs', style: Theme.of(context).textTheme.bodySmall),
                  ]),
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
