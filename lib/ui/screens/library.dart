import 'package:material_ui/material_ui.dart';
import '../../core/platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/appearance.dart';
import '../../core/settings.dart';
import '../../data/follows.dart';
import '../../data/library.dart';
import '../../data/library_pins.dart';
import '../../data/models.dart';
import '../../data/playlist_covers.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../state.dart';
import '../widgets.dart';
import 'smart_playlist.dart';
import 'podcasts.dart';

const _sortTypes = {
  AlbumSort.recent: ('recent', 'Recently played'),
  AlbumSort.newest: ('newest', 'Recently added'),
  AlbumSort.alphabetical: ('alphabeticalByName', 'Name'),
  AlbumSort.artist: ('alphabeticalByArtist', 'Artist'),
  AlbumSort.year: ('byYear', 'Year'),
  AlbumSort.frequent: ('frequent', 'Most played'),
  AlbumSort.starred: ('starred', 'Favourites'),
  AlbumSort.random: ('random', 'Random'),
};

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 7,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Library'),
          actions: [
            IconButton(
              icon: const Icon(Icons.folder_outlined),
              tooltip: 'Folders',
              onPressed: () => context.push('/folders'),
            ),
            IconButton(
              icon: const Icon(Icons.radio_outlined),
              tooltip: 'Radio',
              onPressed: () => context.push('/radio'),
            ),
          ],
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(52),
            child: Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: EdgeInsets.symmetric(horizontal: 8),
                tabs: [
                  Tab(text: 'Playlists', height: 36),
                  Tab(text: 'Podcasts', height: 36),
                  Tab(text: 'Albums', height: 36),
                  Tab(text: 'Artists', height: 36),
                  Tab(text: 'Songs', height: 36),
                  Tab(text: 'Liked', height: 36),
                  Tab(text: 'Genres', height: 36),
                ],
              ),
            ),
          ),
        ),
        body: const TabBarView(
          children: [
            _PlaylistsTab(),
            PodcastsTab(),
            AlbumsTab(),
            _ArtistsTab(),
            _SongsTab(),
            _FavouritesTab(),
            _GenresTab(),
          ],
        ),
      ),
    );
  }
}

/// Paged album grid / list with sort choice. Also used for "see all" from the home screen.
class AlbumsTab extends ConsumerStatefulWidget {
  const AlbumsTab({super.key, this.fixedType});
  final String? fixedType;
  @override
  ConsumerState<AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends ConsumerState<AlbumsTab> {
  void _safeSetState(VoidCallback f) {
    if (mounted) setState(f);
  }

  final _albums = <Album>[];
  bool _loading = false, _done = false;
  String? _error;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String get _type => widget.fixedType ?? _sortTypes[ref.read(settingsProvider).albumSort]!.$1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) _more();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _more());
  }

  Future<void> _reset() async {
    _safeSetState(() {
      _albums.clear();
      _done = false;
      _error = null;
    });
    await _more();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    _safeSetState(() => _loading = true);
    try {
      final repo = ref.read(repoProvider);
      final page = _type == 'starred'
          ? (await repo.starred()).albums
          : await repo.albums(_type, size: 60, offset: _albums.length);
      _safeSetState(() {
        _albums.addAll(page.where((a) => !a.isLookup));
        _done = page.length < 60 || _type == 'starred' || _type == 'random' && _albums.length >= 240;
      });
    } catch (e) {
      _safeSetState(() => _error = '$e');
    } finally {
      if (mounted) _safeSetState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grid = ref.watch(settingsProvider.select((s) => s.albumGrid));
    final sort = ref.watch(settingsProvider.select((s) => s.albumSort));
    ref.listen(
      repoProvider.select((r) => (r.online, r.client)),
      (_, _) => _reset(),
    ); // went on/offline, or another server
    final header = widget.fixedType != null
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                MenuAnchor(
                  builder: (ctx, ctl, _) => TextButton.icon(
                    icon: const Icon(Icons.sort),
                    label: Text(_sortTypes[sort]!.$2),
                    onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
                  ),
                  menuChildren: [
                    for (final e in _sortTypes.entries)
                      MenuItemButton(
                        leadingIcon: Icon(e.key == sort ? Icons.check : null),
                        onPressed: () {
                          ref.read(settingsProvider.notifier).update({'albumSort': e.key.name});
                          _reset();
                        },
                        child: Text(e.value.$2),
                      ),
                  ],
                ),
                const Spacer(),
                IconButton(
                  tooltip: grid ? 'Show as a list' : 'Show as a grid',
                  icon: Icon(grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
                  onPressed: () => ref.read(settingsProvider.notifier).update({'albumGrid': !grid}),
                ),
              ],
            ),
          );
    if (_error != null && _albums.isEmpty) {
      return AsyncView<void>(AsyncError(_error!, StackTrace.empty), (_) => const SizedBox(), onRetry: _reset);
    }
    return RefreshIndicator(
      onRefresh: _reset,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          if (header != null) SliverToBoxAdapter(child: header),
          if (grid)
            SliverPadding(
              padding: const EdgeInsets.all(8),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: AppLook.of(context).gridExtent,
                  childAspectRatio: 0.74,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                delegate: SliverChildBuilderDelegate(
                  (_, i) => AlbumCard(_albums[i], width: double.infinity),
                  childCount: _albums.length,
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: _albums.length,
              itemBuilder: (_, i) {
                final a = _albums[i];
                return GestureDetector(onSecondaryTap: () => showCollectionMenu(
                    context,
                    ref,
                    a.name,
                    () async => (await ref.read(repoProvider).album(a.id)).songs,
                  ), child: ListTile(
                  leading: Cover(a.coverArt, size: AppLook.of(context).compact ? 44 : 52),
                  title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: isDesktop && a.artistId.isNotEmpty
                      ? Row(
                          children: [
                            Flexible(child: NameLink(a.artist, to: NameLink.artistOf(a.artistId))),
                            if (a.year != null) Text(' · ${a.year}'),
                          ],
                        )
                      : Text([a.artist, if (a.year != null) '${a.year}'].join(' · '), maxLines: 1),
                  onTap: () => context.push('/album/${a.id}'),
                  onLongPress: () => showCollectionMenu(
                    context,
                    ref,
                    a.name,
                    () async => (await ref.read(repoProvider).album(a.id)).songs,
                  ),
                ));
              },
            ),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }
}

class AlbumListScreen extends StatelessWidget {
  const AlbumListScreen({super.key, required this.type, required this.title});
  final String type, title;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: AlbumsTab(fixedType: type),
  );
}

class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(ref.watch(artistsProvider), (List<Artist> artists) {
      final list = artists.where((a) => !a.isLookup).toList();
      return RefreshIndicator(
        onRefresh: () async => ref.invalidate(artistsProvider),
        child: ListView.builder(
          itemCount: list.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) return const _FollowingTile();
            final a = list[i - 1];
            return ListTile(
              leading: Cover(a.coverArt, size: 48, circle: true, icon: Icons.person),
              title: Text(a.name),
              subtitle: a.albumCount != null ? Text(plural(a.albumCount!, 'album')) : null,
              trailing: a.starred ? const Icon(Icons.favorite, size: 18) : null,
              onTap: () => context.push('/artist/${a.id}'),
            );
          },
        ),
      );
    }, onRetry: () => ref.invalidate(artistsProvider));
  }
}

/// Top of the Artists tab: the artists you follow, with their new releases and shows.
class _FollowingTile extends ConsumerWidget {
  const _FollowingTile();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final n = ref.watch(followsProvider).length;
    return ListTile(
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: cs.primaryContainer,
        child: Icon(Icons.how_to_reg_rounded, color: cs.onPrimaryContainer),
      ),
      title: const Text('Followed artists'),
      subtitle: Text(n == 0 ? 'New releases and shows from artists you follow' : '${plural(n, 'artist')} · new releases · shows'),
      onTap: () => context.push('/following'),
    );
  }
}

class _SongsTab extends ConsumerStatefulWidget {
  const _SongsTab();
  @override
  ConsumerState<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends ConsumerState<_SongsTab> {
  void _safeSetState(VoidCallback f) {
    if (mounted) setState(f);
  }

  final _songs = <Song>[];
  bool _loading = false, _done = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 800) _more();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _more());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    _safeSetState(() => _loading = true);
    try {
      final page = await ref.read(repoProvider).allSongs(size: 200, offset: _songs.length);
      _safeSetState(() {
        _songs.addAll(page);
        _done = page.length < 200;
      });
    } catch (_) {
      _done = true;
    } finally {
      if (mounted) _safeSetState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      itemCount: _songs.length + 2,
      itemBuilder: (_, i) {
        if (i == 0) {
          return PlayButtons(
            source: 'songs',
            onPlay: () async =>
                audioHandler.playSongs(await ref.read(repoProvider).randomSongs(size: 500), source: 'songs'),
            onShuffle: () async => audioHandler.playSongs(
              await ref.read(repoProvider).randomSongs(size: 500),
              shuffle: true,
              source: 'songs',
            ),
          );
        }
        if (i == _songs.length + 1) {
          return _loading
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              : const SizedBox(height: 16);
        }
        return SongTile(_songs[i - 1], list: _songs, index: i - 1);
      },
    );
  }
}

class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(repoProvider).online;
    return Scaffold(
      floatingActionButton: online
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('New playlist'),
              onPressed: () => showNewPlaylistSheet(context, ref),
            )
          : null,
      body: AsyncView(ref.watch(playlistsProvider), (List<Playlist> lists) {
        final covers = ref.watch(playlistCoversProvider);
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(playlistsProvider),
          child: ListView(
            children: [
              const _LikedTile(),
              for (final pin in ref.watch(libraryPinsProvider)) _PinnedTile(pin),
              if (lists.isNotEmpty) const SectionTitle('Playlists'),
              for (final p in lists)
                GestureDetector(onSecondaryTap: () => showCollectionMenu(
                    context,
                    ref,
                    p.name,
                    () async => (await ref.read(repoProvider).playlist(p.id)).songs,
                    pin: LibraryPin('playlist', p.id, p.name, cover: p.coverArt, subtitle: 'Playlist'),
                  ), child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  leading: Cover(
                    shownPlaylistCover(covers[p.id], p.coverArt),
                    size: 54,
                    icon: Icons.queue_music_rounded,
                  ),
                  title: Text(p.name, style: Theme.of(context).textTheme.titleSmall),
                  subtitle: Row(
                    children: [
                      if (ref.watch(downloadsProvider).pins.contains('playlist:${p.id}'))
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(
                            Icons.arrow_circle_down_rounded,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      Text('${p.songCount ?? 0} songs · ${formatDuration(p.duration)}'),
                    ],
                  ),
                  onTap: () => context.push('/playlist/${p.id}'),
                  onLongPress: () => showCollectionMenu(
                    context,
                    ref,
                    p.name,
                    () async => (await ref.read(repoProvider).playlist(p.id)).songs,
                    pin: LibraryPin('playlist', p.id, p.name, cover: p.coverArt, subtitle: 'Playlist'),
                  ),
                )),
              const SizedBox(height: 88),
            ],
          ),
        );
      }, onRetry: () => ref.invalidate(playlistsProvider)),
    );
  }
}

class _GenresTab extends ConsumerWidget {
  const _GenresTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(ref.watch(genresProvider), (List<Genre> genres) {
      return ListView(
        children: [
          for (final g in genres)
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: Text(g.name),
              subtitle: Text(
                [if (g.albumCount > 0) plural(g.albumCount, 'album'), if (g.songCount > 0) nSongs(g.songCount)].join(' · '),
              ),
              onTap: () => context.push('/genre/${Uri.encodeComponent(g.name)}'),
            ),
        ],
      );
    }, onRetry: () => ref.invalidate(genresProvider));
  }
}

/// Liked songs as a playlist of its own (pinned at the top of the Library, like Spotify's).
class LikedSongsScreen extends StatelessWidget {
  const LikedSongsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Liked songs')),
    body: const _FavouritesTab(songsOnly: true),
  );
}

class _LikedTile extends ConsumerWidget {
  const _LikedTile();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final n = ref.watch(starredProvider).value?.songs.where((s) => !s.isLookup).length;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primary, cs.tertiary],
          ),
        ),
        child: Icon(Icons.favorite_rounded, color: cs.onPrimary, size: 26),
      ),
      title: Text('Liked songs', style: Theme.of(context).textTheme.titleSmall),
      subtitle: Row(
        children: [
          Icon(Icons.push_pin, size: 13, color: cs.primary),
          const SizedBox(width: 4),
          Text(n == null ? 'Playlist' : 'Playlist · ${nSongs(n)}'),
        ],
      ),
      onTap: () => context.push('/liked'),
    );
  }
}

/// A pinned playlist's cover as the server has it now (the pin keeps the one it had when pinned).
String _serverCover(WidgetRef ref, LibraryPin pin) {
  for (final p in ref.watch(playlistsProvider).value ?? const <Playlist>[]) {
    if (p.id == pin.id) return p.coverArt;
  }
  return pin.cover;
}

class _PinnedTile extends ConsumerWidget {
  const _PinnedTile(this.pin);
  final LibraryPin pin;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final album = pin.kind == 'album';
    return GestureDetector(onSecondaryTap: () => showCollectionMenu(
        context,
        ref,
        pin.name,
        () async => album
            ? (await ref.read(repoProvider).album(pin.id)).songs
            : (await ref.read(repoProvider).playlist(pin.id)).songs,
        pin: pin,
      ), child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Cover(
        pin.kind == 'playlist'
            ? shownPlaylistCover(ref.watch(playlistCoversProvider)[pin.id], _serverCover(ref, pin))
            : pin.cover,
        size: 54,
        icon: album ? Icons.album_outlined : Icons.queue_music_rounded,
      ),
      title: Text(
        pin.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      subtitle: Row(
        children: [
          Icon(Icons.push_pin, size: 13, color: cs.primary),
          const SizedBox(width: 4),
          Expanded(child: Text(pin.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
      onTap: () => context.push('/${pin.kind}/${pin.id}'),
      onLongPress: () => showCollectionMenu(
        context,
        ref,
        pin.name,
        () async => album
            ? (await ref.read(repoProvider).album(pin.id)).songs
            : (await ref.read(repoProvider).playlist(pin.id)).songs,
        pin: pin,
      ),
    ));
  }
}

class _FavouritesTab extends ConsumerWidget {
  const _FavouritesTab({this.songsOnly = false});
  final bool songsOnly;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncView(ref.watch(starredProvider), (SearchResult r) {
      final songs = r.songs.where((s) => !s.isLookup).toList();
      return RefreshIndicator(
        onRefresh: () async => ref.invalidate(starredProvider),
        child: LazyListView(
          count: songs.length,
          itemBuilder: (_, i) => SongTile(songs[i], list: songs, index: i, playContext: const PlayContext.liked()),
          footer: [
            if (r.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('Nothing hearted yet')),
              ),
          ],
          header: [
            if (songs.isNotEmpty)
              PlayButtons(
                source: const PlayContext.liked().key,
                onPlay: () => audioHandler.playSongs(songs, context: const PlayContext.liked()),
                onShuffle: () => audioHandler.playSongs(songs, shuffle: true, context: const PlayContext.liked()),
                leading: [DownloadToggle(pinKey: 'starred', songs: () async => songs)],
              ),
            if (!songsOnly && r.artists.isNotEmpty) ...[
              const SectionTitle('Artists'),
              for (final a in r.artists)
                ListTile(
                  leading: Cover(a.coverArt, size: 44, circle: true, icon: Icons.person),
                  title: Text(a.name),
                  onTap: () => context.push('/artist/${a.id}'),
                ),
            ],
            if (!songsOnly && r.albums.isNotEmpty)
              Shelf(title: 'Albums', children: [for (final a in r.albums) AlbumCard(a)]),
            if (songs.isNotEmpty) ...[
              if (!songsOnly) SectionTitle('Liked songs', subtitle: nSongs(songs.length)),
              if (songsOnly)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(nSongs(songs.length), style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ],
        ),
      );
    }, onRetry: () => ref.invalidate(starredProvider));
  }
}
