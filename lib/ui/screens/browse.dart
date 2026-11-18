import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/account.dart';
import '../../data/artist_extra.dart';
import '../../data/library.dart';
import '../../data/library_pins.dart';
import '../../data/models.dart';
import '../../data/updates.dart' show openUrl;
import '../../data/share_links.dart';
import '../../data/radio_browser.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../state.dart';
import '../widgets.dart';
import '../../data/playlist_covers.dart';
import 'playlist_edit.dart';
import 'smart_playlist.dart';
import 'radio.dart';

/// Re-loads a page every 20 s while it shows songs that are being downloaded (⏳ → real song).
mixin _PollWhileDownloading<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  Timer? _poll;
  void pollIf(bool downloading, VoidCallback refresh) {
    if (downloading && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 20), (_) => refresh());
    } else if (!downloading && _poll != null) {
      _poll!.cancel();
      _poll = null;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}

/// Page header: blurred artwork behind, the cover, then title and details, left-aligned.
class _Header extends StatelessWidget {
  const _Header({
    required this.cover,
    required this.title,
    required this.lines,
    this.circle = false,
    this.icon = Icons.album_outlined,
    this.artist = '',
    this.album = '',
    this.onCoverTap,
  });
  final String cover, title, artist, album;
  final List<Widget> lines;
  final bool circle;
  final IconData icon;
  final VoidCallback? onCoverTap; // e.g. change a playlist's picture
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final w = MediaQuery.sizeOf(context).width;
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final size = (w * 0.6).clamp(160.0, 300.0);
    return Stack(
      children: [
        Positioned.fill(
          child: ArtBackdrop(cover: cover, artist: artist, album: album, strength: 0.35),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, top + 4, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: GestureDetector(
                  onTap: onCoverTap,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: circle ? BoxShape.circle : BoxShape.rectangle,
                      borderRadius: circle ? null : BorderRadius.circular(18),
                      boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 40, offset: Offset(0, 16))],
                    ),
                    child: Semantics(
                      button: onCoverTap != null,
                      label: onCoverTap != null ? 'Change picture' : null,
                      child: Cover(
                        cover,
                        size: size,
                        radius: 18,
                        circle: circle,
                        icon: icon,
                        artist: artist,
                        album: album,
                        artistImage: circle,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(title, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5)),
              const SizedBox(height: 6),
              ...lines,
            ],
          ),
        ),
      ],
    );
  }
}

// ── Album ──
class AlbumScreen extends ConsumerStatefulWidget {
  const AlbumScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> with _PollWhileDownloading {
  final _title = ScrollTitle();
  @override
  Widget build(BuildContext context) {
    final album = ref.watch(albumProvider(widget.id));
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: overArtBar(context),
        surfaceTintColor: Colors.transparent,
        title: _title.title(album.value?.name ?? ''),
      ),
      body: _title.wrap(AsyncView(album, (Album a) {
        pollIf(a.songs.any((s) => s.lookup == LookupState.downloading), () => ref.invalidate(albumProvider(widget.id)));
        final playable = a.songs.where((s) => !s.isLookup).toList();
        final missing = a.songs.length - playable.length;
        final discs = a.songs.map((s) => s.disc ?? 1).toSet();
        final children = <Widget>[];
        int? lastDisc;
        for (final s in a.songs) {
          if (discs.length > 1 && s.disc != lastDisc) {
            lastDisc = s.disc;
            children.add(SectionTitle('Disc ${s.disc ?? 1}'));
          }
          children.add(SongTile(s, list: playable, showTrack: true, playContext: PlayContext.album(a.id, a.name)));
        }
        final t = Theme.of(context).textTheme;
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(albumProvider(widget.id)),
          child: ListView(
            children: [
              _Header(
                cover: a.coverArt,
                title: a.name,
                artist: a.artist,
                album: a.name,
                lines: [
                  GestureDetector(
                    onTap: a.artistId.isEmpty ? null : () => context.push('/artist/${a.artistId}'),
                    child: Text(a.artist, style: t.titleSmall),
                  ),
                  Text(
                    [
                      if (a.year != null) '${a.year}',
                      if (a.genre.isNotEmpty) a.genre,
                      nSongs(a.songs.length),
                      formatDuration(a.duration ?? a.songs.fold<int>(0, (n, s) => n + (s.duration ?? 0))),
                    ].join(' · '),
                    style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              if (a.isLookup || missing > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.cloud_download_outlined),
                      title: Text(
                        a.isLookup ? 'This album isn\'t in your library' : (missing == 1 ? '1 song isn\'t in your library' : '$missing songs aren\'t in your library'),
                      ),
                      subtitle: const Text('Download them from Soulseek through your server'),
                      trailing: FilledButton.tonal(
                        onPressed: () => toggleStarAlbum(context, ref, a),
                        child: const Text('Get'),
                      ),
                    ),
                  ),
                ),
              if (playable.isNotEmpty)
                PlayButtons(
                  source: PlayContext.album(a.id, a.name).key,
                  onPlay: () => audioHandler.playSongs(playable, context: PlayContext.album(a.id, a.name)),
                  onShuffle: () =>
                      audioHandler.playSongs(playable, shuffle: true, context: PlayContext.album(a.id, a.name)),
                  leading: [
                    DownloadToggle(pinKey: 'album:${a.id}', songs: () async => playable),
                    IconButton(
                      iconSize: 26,
                      icon: Icon(
                        a.starred ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: a.starred ? Theme.of(context).colorScheme.primary : null,
                      ),
                      onPressed: () => toggleStarAlbum(context, ref, a),
                    ),
                    if (ref.watch(repoProvider).online)
                      IconButton(
                        tooltip: 'Share',
                        icon: const Icon(Icons.share_outlined),
                        onPressed: () => shareLink(context, '${a.name} · ${a.artist}', () => albumLink(a)),
                      ),
                    IconButton(
                      icon: const Icon(Icons.more_vert_rounded),
                      onPressed: () => showCollectionMenu(
                        context,
                        ref,
                        a.name,
                        () async => playable,
                        pin: LibraryPin('album', a.id, a.name, cover: a.coverArt, subtitle: 'Album · ${a.artist}'),
                      ),
                    ),
                  ],
                ),
              ...children,
              const SizedBox(height: 24),
            ],
          ),
        );
      }, onRetry: () => ref.invalidate(albumProvider(widget.id)))),
    );
  }
}

// ── Artist ──
class ArtistScreen extends ConsumerStatefulWidget {
  const ArtistScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> with _PollWhileDownloading {
  final _title = ScrollTitle();
  bool _bioOpen = false;
  bool _allPopular = false;

  static String _compact(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(n >= 10000000 ? 0 : 1)}M'
      : n >= 1000
      ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K'
      : '$n';

  /// Popular songs: the artist's top 10 (Deezer), your own copy when you have it, ⬇ when you don't.
  List<Widget> _popular(BuildContext context, Artist a, List<Song> topOwn, ArtistExtra extra, List<Song> own) {
    var list = <Song>[];
    if (extra.top.isEmpty) {
      list = topOwn;
    } else {
      final mine = {
        for (final s in [...topOwn, ...own]) normName(s.title): s,
      };
      list = [for (final s in extra.top) mine[normName(s.title)] ?? s];
    }
    if (list.isEmpty) return const [];
    final shown = list.take(_allPopular ? 10 : 5).toList();
    final playable = shown.where((s) => !s.isLookup).toList();
    return [
      const SectionTitle('Popular'),
      for (var i = 0; i < shown.length; i++)
        shown[i].isLookup ? SongTile(shown[i]) : SongTile(shown[i], list: playable, index: playable.indexOf(shown[i])),
      if (list.length > 5)
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: TextButton(
            onPressed: () => setState(() => _allPopular = !_allPopular),
            child: Text(_allPopular ? 'Show less' : 'See more'),
          ),
        ),
    ];
  }

  /// Everything they released: albums, singles & EPs, compilations. Yours open normally; the rest are ⬇.
  List<Widget> _discography(List<Album> own, List<Album> missing, ArtistExtra extra) {
    Shelf shelf(String title, List<Album> l) => Shelf(
      title: title,
      textHeight: 72,
      children: [for (final al in l) AlbumCard(al, showArtist: false, showYear: true)],
    );
    if (extra.albums.isEmpty) {
      return [if (own.isNotEmpty) shelf('Albums', own), if (missing.isNotEmpty) shelf('Not in your library', missing)];
    }
    final byName = {for (final al in own) normName(al.name): al};
    final used = <String>{};
    final groups = <String, List<Album>>{'album': [], 'single': [], 'compile': []};
    for (final (al, type) in extra.albums) {
      final k = normName(al.name);
      final mine = byName[k];
      if (mine != null) used.add(mine.id);
      final g = type == 'ep' || type == 'single' ? 'single' : (type == 'compile' ? 'compile' : 'album');
      groups[g]!.add(mine ?? al);
    }
    // your albums Deezer doesn't list (live recordings, bootlegs...) still show, first
    final extraOwn = own.where((al) => !used.contains(al.id)).toList();
    groups['album'] = [...extraOwn, ...groups['album']!];
    return [
      if (groups['album']!.isNotEmpty) shelf('Albums', groups['album']!),
      if (groups['single']!.isNotEmpty) shelf('Singles and EPs', groups['single']!),
      if (groups['compile']!.isNotEmpty) shelf('Compilations', groups['compile']!),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final artist = ref.watch(artistProvider(widget.id));
    final info = ref.watch(artistInfoProvider(widget.id));
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: overArtBar(context),
        surfaceTintColor: Colors.transparent,
        title: _title.title(artist.value?.name ?? ''),
      ),
      body: _title.wrap(AsyncView(artist, (Artist a) {
        final own = a.albums.where((x) => !x.isLookup).toList()..sort((x, y) => (y.year ?? 0).compareTo(x.year ?? 0));
        final missing = a.albums.where((x) => x.isLookup).toList();
        pollIf(
          missing.any((x) => x.lookup == LookupState.downloading),
          () => ref.invalidate(artistProvider(widget.id)),
        );
        final extraAsync = ref.watch(artistExtraProvider(a.name));
        final extra = extraAsync.value ?? const ArtistExtra();
        // the server's own top songs only when Deezer has none (it's the slower of the two)
        final top = !extraAsync.isLoading && extra.top.isEmpty
            ? ref.watch(topSongsProvider(a.name)).value ?? const <Song>[]
            : const <Song>[];
        final topOwn = top.where((s) => !s.isLookup).take(5).toList();
        final bio = info.value?.biography ?? '';
        final (wiki, wikiUrl) = info.hasValue && bio.isEmpty
            ? ref.watch(artistWikiProvider(a.name)).value ?? ('', '')
            : ('', '');
        final ownSongs = ref.watch(ownArtistSongsProvider(a.name)).value ?? const <Song>[];
        final bioText = bio.isNotEmpty ? bio : wiki;
        final fans = extra.fans;
        final t = Theme.of(context).textTheme;
        Future<List<Song>> allSongs() async {
          final repo = ref.read(repoProvider);
          final out = <Song>[];
          for (final al in own) {
            out.addAll((await repo.album(al.id)).songs.where((s) => !s.isLookup));
          }
          return out;
        }

        return ListView(
          children: [
            _Header(
              cover: a.coverArt,
              title: a.name,
              circle: true,
              icon: Icons.person_outline,
              artist: a.name,
              lines: [
                Text(
                  [
                    if (fans != null) '${_compact(fans)} fans',
                    own.length == 1 ? '1 album in your library' : '${own.length} albums in your library',
                  ].join(' · '),
                  style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            PlayButtons(
              source: 'artist:${a.id}',
              onPlay: () async => audioHandler.playSongs(await allSongs(), source: 'artist:${a.id}'),
              onShuffle: () async => audioHandler.playSongs(await allSongs(), shuffle: true, source: 'artist:${a.id}'),
              leading: [
                IconButton(
                  iconSize: 26,
                  icon: Icon(
                    a.starred ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    color: a.starred ? Theme.of(context).colorScheme.primary : null,
                  ),
                  onPressed: () => toggleStarArtist(context, ref, a),
                ),
                IconButton(
                  tooltip: 'Share',
                  icon: const Icon(Icons.share_outlined),
                  onPressed: () => shareLink(context, a.name, () => artistLink(a.id, a.name)),
                ),
                IconButton(
                  tooltip: 'Artist radio',
                  icon: const Icon(Icons.radio_rounded),
                  onPressed: () async {
                    final songs = topOwn.isNotEmpty ? topOwn : (await allSongs());
                    if (songs.isNotEmpty && context.mounted) openSongRadio(context, songs.first);
                  },
                ),
              ],
            ),
            ..._popular(context, a, topOwn, extra, ownSongs),
            if (bioText.isNotEmpty) ...[
              const SectionTitle('About'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => setState(() => _bioOpen = !_bioOpen),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (fans != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                '${_compact(fans)} fans on Deezer',
                                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                          Text(
                            bioText,
                            maxLines: _bioOpen ? null : 4,
                            overflow: _bioOpen ? null : TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          if (_bioOpen && bio.isEmpty && wikiUrl.isNotEmpty)
                            TextButton.icon(
                              style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                              icon: const Icon(Icons.open_in_new_rounded, size: 16),
                              label: const Text('From Wikipedia: read the whole article'),
                              onPressed: () => openUrl(wikiUrl).catchError((_) {}),
                            )
                          else
                            Text(
                              _bioOpen ? (bio.isEmpty ? 'From Wikipedia' : '') : 'Read more',
                              style: t.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            ..._discography(own, missing, extra),
            ...switch (ref.watch(soundAlikeArtistsProvider(a.name))) {
              AsyncData(:final value) when value.isNotEmpty => [
                Shelf(
                  title: 'Sounds like',
                  height: 150,
                  children: [
                    for (final s in value)
                      SizedBox(
                        width: 110,
                        child: InkWell(
                          onTap: () async {
                            final hit = s.id.isNotEmpty
                                ? s
                                : (await ref.read(repoProvider).search(s.name)).artists.firstOrNull;
                            if (hit != null && context.mounted) context.push('/artist/${hit.id}');
                          },
                          child: Column(
                            children: [
                              Cover(
                                'ar-${s.id}',
                                size: 96,
                                circle: true,
                                icon: Icons.person_outline,
                                artist: s.name,
                                artistImage: true,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                s.name,
                                maxLines: 2,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              _ => const <Widget>[],
            },
            if ((info.value?.similar ?? const []).isNotEmpty)
              Shelf(
                title: 'Similar artists (Last.fm)',
                height: 150,
                children: [
                  for (final s in info.value!.similar)
                    SizedBox(
                      width: 110,
                      child: InkWell(
                        onTap: s.id.isEmpty ? null : () => context.push('/artist/${s.id}'),
                        child: Column(
                          children: [
                            Cover(s.coverArt, size: 96, circle: true, icon: Icons.person),
                            const SizedBox(height: 6),
                            Text(
                              s.name,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 24),
          ],
        );
      }, onRetry: () => ref.invalidate(artistProvider(widget.id)))),
    );
  }
}

// ── Playlist (with editing) ──
class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> with _PollWhileDownloading {
  final _title = ScrollTitle();
  bool _editing = false;
  List<Song>? _edit;

  Future<void> _save() async {
    final c = ref.read(clientProvider);
    if (c == null || _edit == null) return;
    try {
      await c.setPlaylistSongs(widget.id, _edit!.map((s) => s.id).toList());
      ref.invalidate(playlistProvider(widget.id));
      ref.invalidate(playlistsProvider);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t save: $e');
    }
    if (!mounted) return;
    setState(() {
      _editing = false;
      _edit = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pl = ref.watch(playlistProvider(widget.id));
    final online = ref.watch(repoProvider).online;
    ref.watch(playlistRulesProvider(widget.id)); // is it a smart playlist? (for the menu)
    return Scaffold(
      extendBodyBehindAppBar: !_editing,
      appBar: AppBar(
        backgroundColor: _editing ? null : overArtBar(context),
        surfaceTintColor: Colors.transparent,
        title: _editing ? const Text('Edit playlist') : _title.title(pl.value?.name ?? ''),
        actions: [
          if (_editing)
            TextButton(onPressed: _save, child: const Text('Save'))
          else if (pl.hasValue && online)
            PopupMenuButton<String>(
              onSelected: (v) async {
                final p = pl.value!;
                final rules = ref.read(playlistRulesProvider(widget.id)).value;
                final c = ref.read(clientProvider);
                if (c == null) return;
                try {
                  switch (v) {
                    case 'rules':
                      await Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute(builder: (_) => SmartPlaylistScreen(id: p.id, name: p.name, rules: rules)),
                      );
                    case 'edit':
                      setState(() {
                        _editing = true;
                        _edit = [...p.songs];
                      });
                    case 'details':
                      await showPlaylistDetails(context, ref, p);
                    case 'picture':
                      await showPlaylistPicture(context, ref, p);
                    case 'menu':
                      showCollectionMenu(
                        context,
                        ref,
                        p.name,
                        () async => p.songs,
                        pin: LibraryPin('playlist', p.id, p.name, cover: p.coverArt, subtitle: 'Playlist'),
                      );
                    case 'delete':
                      if (await confirm(context, 'Delete "${p.name}"?', 'This deletes the playlist on your server.')) {
                        await c.deletePlaylist(p.id);
                        await ref.read(playlistCoversProvider.notifier).forget(p.id);
                        ref.invalidate(playlistsProvider);
                        if (context.mounted) context.pop();
                      }
                  }
                } catch (e) {
                  if (context.mounted) toast(context, "Couldn't do that: $e");
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'menu', child: Text('Pin, queue, download…')),
                const PopupMenuItem(value: 'details', child: Text('Edit name and description')),
                const PopupMenuItem(value: 'picture', child: Text('Change picture')),
                if (ref.read(playlistRulesProvider(widget.id)).value != null)
                  const PopupMenuItem(value: 'rules', child: Text('Edit rules'))
                else
                  const PopupMenuItem(value: 'edit', child: Text('Reorder / remove songs')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
      body: _title.wrap(AsyncView(pl, (Playlist p) {
        if (_editing) {
          return ReorderableListView.builder(
            itemCount: _edit!.length,
            onReorder: (a, b) => setState(() {
              if (b > a) b--;
              _edit!.insert(b, _edit!.removeAt(a));
            }),
            itemBuilder: (_, i) {
              final s = _edit![i];
              return Dismissible(
                key: ValueKey('${s.id}-$i'),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Theme.of(context).colorScheme.errorContainer,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 24),
                  child: const Icon(Icons.delete_outline),
                ),
                onDismissed: (_) => setState(() => _edit!.removeAt(i)),
                child: ListTile(
                  leading: Cover(s.coverArt, size: 44, icon: Icons.music_note),
                  title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(s.artist, maxLines: 1),
                  trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                ),
              );
            },
          );
        }
        final songs = p.songs.where((s) => !s.isLookup).toList();
        final pending = p.songs.length - songs.length;
        final mine = ref.watch(playlistCoversProvider)[p.id];
        if (coverIsStale(mine, p.coverArt)) {
          // the server has the new picture now: the phone's copy can go
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => ref.read(playlistCoversProvider.notifier).tidy(p.id, p.coverArt),
          );
        }
        pollIf(pending > 0, () => ref.invalidate(playlistProvider(widget.id)));
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(playlistProvider(widget.id)),
          child: LazyListView(
            header: [
              _Header(
                cover: shownPlaylistCover(mine, p.coverArt),
                title: p.name,
                icon: Icons.queue_music_rounded,
                onCoverTap: online ? () => showPlaylistPicture(context, ref, p) : null,
                lines: [
                  if (p.comment.isNotEmpty) Text(p.comment, style: Theme.of(context).textTheme.bodyMedium),
                  Text(
                    '${nSongs(p.songs.length)} · ${formatDuration(p.duration ?? p.songs.fold<int>(0, (n, s) => n + (s.duration ?? 0)))}'
                    '${online ? (p.public ? ' · Public' : ' · Private') : ''}'
                    '${pending > 0 ? ' · $pending waiting to download' : ''}',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              if (songs.isNotEmpty)
                PlayButtons(
                  source: PlayContext.playlist(p.id, p.name).key,
                  onPlay: () => audioHandler.playSongs(songs, context: PlayContext.playlist(p.id, p.name)),
                  onShuffle: () =>
                      audioHandler.playSongs(songs, shuffle: true, context: PlayContext.playlist(p.id, p.name)),
                  leading: [DownloadToggle(pinKey: 'playlist:${p.id}', songs: () async => songs)],
                ),
            ],
            count: p.songs.length,
            itemBuilder: (_, i) => SongTile(p.songs[i], list: songs, playContext: PlayContext.playlist(p.id, p.name)),
            footer: const [SizedBox(height: 24)],
          ),
        );
      }, onRetry: () => ref.invalidate(playlistProvider(widget.id)))),
    );
  }
}

// ── Genre ──
class GenreScreen extends ConsumerWidget {
  const GenreScreen({super.key, required this.name});
  final String name;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(genreAlbumsProvider(name));
    final songs = ref.watch(genreSongsProvider(name));
    final list = songs.value ?? const <Song>[];
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: LazyListView(
        count: list.length,
        itemBuilder: (_, i) => SongTile(list[i], list: list, index: i),
        header: [
          PlayButtons(
            source: 'genre:$name',
            onPlay: () async => audioHandler.playSongs(
              await ref.read(repoProvider).randomSongs(size: 200, genre: name),
              source: 'genre:$name',
            ),
            onShuffle: () async => audioHandler.playSongs(
              await ref.read(repoProvider).randomSongs(size: 200, genre: name),
              shuffle: true,
              source: 'genre:$name',
            ),
          ),
          albums.when(
            data: (l) => Shelf(title: 'Albums', children: [for (final a in l.where((a) => !a.isLookup)) AlbumCard(a)]),
            loading: () => const SizedBox(height: 40),
            error: (_, _) => const SizedBox.shrink(),
          ),
          ...switch (songs) {
            AsyncData(:final value) => [SectionTitle('Songs (${value.length})')],
            AsyncError(:final error) => [Padding(padding: const EdgeInsets.all(16), child: Text('$error'))],
            _ => [
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
          },
        ],
      ),
    );
  }
}

// ── Folders (browse the music folders as they are on the server) ──
class FoldersScreen extends ConsumerStatefulWidget {
  const FoldersScreen({super.key, this.id, this.title});
  final String? id, title;
  @override
  ConsumerState<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends ConsumerState<FoldersScreen> {
  late Future<List<DirEntry>> _future;

  @override
  void initState() {
    super.initState();
    final c = ref.read(clientProvider);
    final id = widget.id;
    _future = c == null
        ? Future.error('Not signed in')
        : id == null
        // your real folders when the server can show them; else Navidrome's (artist / album) view
        ? c.realFolder('').then((r) => r ?? c.indexes())
        : id.startsWith('path:')
        ? c.realFolder(id.substring(5)).then((r) => r ?? (throw Exception("Couldn't open this folder")))
        : c.directory(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? 'Folders')),
      body: FutureBuilder<List<DirEntry>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final entries = snap.data!;
          final songs = entries.where((e) => !e.isDir && e.song != null).map((e) => e.song!).toList();
          final dirs = entries.where((e) => e.isDir).toList();
          return LazyListView(
            header: [
              if (songs.isNotEmpty)
                PlayButtons(
                  source: 'folder:${widget.id}',
                  onPlay: () => audioHandler.playSongs(songs, source: 'folder:${widget.id}'),
                  onShuffle: () => audioHandler.playSongs(songs, shuffle: true, source: 'folder:${widget.id}'),
                ),
            ],
            count: dirs.length + songs.length,
            itemBuilder: (_, i) {
              if (i >= dirs.length) return SongTile(songs[i - dirs.length], list: songs, index: i - dirs.length);
              final e = dirs[i];
              return ListTile(
                leading: e.coverArt.isNotEmpty ? Cover(e.coverArt, size: 44) : const Icon(Icons.folder_outlined),
                title: Text(e.name),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => FoldersScreen(id: e.id, title: e.name)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ── Internet radio (stations saved in Navidrome) ──
class RadioScreen extends ConsumerWidget {
  const RadioScreen({super.key});

  static Widget art(String streamUrl, {double size = 48}) {
    final pic = stationArt(streamUrl);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      child: Icon(Icons.radio_rounded, size: size * 0.5),
    );
    if (pic == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(pic, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, InternetRadio r) async {
    final v = await showModalBottomSheet<String>(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(r.name, style: Theme.of(ctx).textTheme.titleMedium)),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || v == null) return;
    final c = ref.read(clientProvider);
    if (c == null) return;
    try {
      if (v == 'delete') {
        if (!await confirm(context, 'Delete "${r.name}"?', 'It is removed from your server for every app.')) return;
        await c.deleteRadio(r.id);
      } else {
        final edited = await showStationForm(context, initial: r);
        if (edited == null) return;
        await c.updateRadio(r.id, edited.name, edited.streamUrl, homePageUrl: edited.homePageUrl);
      }
      ref.invalidate(radiosProvider);
    } catch (e) {
      if (context.mounted) toast(context, "Couldn't change the station: $e");
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(repoProvider).online;
    final playing = ref.watch(mediaItemProvider).value?.id;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Internet radio')),
      floatingActionButton: online
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('Add station'),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddStationScreen()));
                ref.invalidate(radiosProvider);
              },
            )
          : null,
      body: AsyncView(ref.watch(radiosProvider), (List<InternetRadio> list) {
        if (list.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No radio stations yet. Tap Add station to find one or paste its address.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(radiosProvider),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              for (final r in list)
                GestureDetector(onSecondaryTap: () => _menu(context, ref, r), child: ListTile(
                  leading: art(r.streamUrl),
                  title: Text(
                    r.name,
                    style: playing == 'radio-${r.id}'
                        ? TextStyle(color: cs.primary, fontWeight: FontWeight.w600)
                        : null,
                  ),
                  subtitle: Text(
                    r.homePageUrl.isNotEmpty ? r.homePageUrl : r.streamUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(icon: const Icon(Icons.more_vert), onPressed: () => _menu(context, ref, r)),
                  onLongPress: () => _menu(context, ref, r),
                  onTap: () {
                    final pic = stationArt(r.streamUrl);
                    audioHandler.playRadio(r, art: pic == null ? null : Uri.tryParse(pic));
                  },
                )),
            ],
          ),
        );
      }),
    );
  }
}

/// Name / stream address / homepage form for a station. Returns null when cancelled.
Future<InternetRadio?> showStationForm(BuildContext context, {InternetRadio? initial}) {
  final name = TextEditingController(text: initial?.name ?? '');
  final url = TextEditingController(text: initial?.streamUrl ?? '');
  final home = TextEditingController(text: initial?.homePageUrl ?? '');
  return showDialog<InternetRadio>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(initial == null ? 'Add a station' : 'Edit station'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
              textInputAction: TextInputAction.next,
            ),
            TextField(
              controller: url,
              decoration: const InputDecoration(labelText: 'Stream address', hintText: 'https://…'),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
            ),
            TextField(
              controller: home,
              decoration: const InputDecoration(labelText: 'Website (optional)'),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final u = url.text.trim();
            if (name.text.trim().isEmpty || !(u.startsWith('http://') || u.startsWith('https://'))) {
              toast(ctx, 'Give it a name and an http(s) stream address');
              return;
            }
            Navigator.pop(ctx, InternetRadio(initial?.id ?? '', name.text.trim(), u, home.text.trim()));
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Find stations in the Radio Browser directory (or paste an address) and save them to your server.
class AddStationScreen extends ConsumerStatefulWidget {
  const AddStationScreen({super.key});
  @override
  ConsumerState<AddStationScreen> createState() => _AddStationScreenState();
}

class _AddStationScreenState extends ConsumerState<AddStationScreen> {
  final _ctl = TextEditingController();
  late Future<List<RadioBrowserStation>> _results = searchStations('');
  final _added = <String>{};
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _search(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _results = searchStations(q));
    });
  }

  Future<void> _add(String name, String url, String homepage, String favicon) async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    try {
      await c.createRadio(name, url, homePageUrl: homepage);
      rememberStationArt(url, favicon);
      if (mounted) setState(() => _added.add(url));
      if (mounted) toast(context, 'Added $name');
    } catch (e) {
      if (mounted) toast(context, "Couldn't add it (your account must be a Navidrome admin): $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add station'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('By address'),
            onPressed: () async {
              final r = await showStationForm(context);
              if (r != null) await _add(r.name, r.streamUrl, r.homePageUrl, '');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchBar(
              controller: _ctl,
              hintText: 'Search stations (name, city, genre…)',
              leading: const Icon(Icons.search),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: _search,
            ),
          ),
          Expanded(
            child: FutureBuilder<List<RadioBrowserStation>>(
              future: _results,
              builder: (_, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) return Center(child: Text('${snap.error}'));
                final list = snap.data ?? const <RadioBrowserStation>[];
                if (list.isEmpty) return const Center(child: Text('No stations found'));
                return ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        _ctl.text.trim().isEmpty ? 'Most listened' : 'Results from Radio Browser',
                        style: t.labelLarge?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                    for (final st in list)
                      ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: st.favicon.startsWith('http')
                              ? Image.network(
                                  st.favicon,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const SizedBox(width: 48, height: 48, child: Icon(Icons.radio_rounded)),
                                )
                              : const SizedBox(width: 48, height: 48, child: Icon(Icons.radio_rounded)),
                        ),
                        title: Text(st.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(st.details, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => audioHandler.playRadio(
                          InternetRadio('preview', st.name, st.url, st.homepage),
                          art: Uri.tryParse(st.favicon),
                        ),
                        trailing: _added.contains(st.url)
                            ? Icon(Icons.check_circle, color: cs.primary)
                            : IconButton(
                                tooltip: 'Add to my stations',
                                icon: const Icon(Icons.add_circle_outline),
                                onPressed: () => _add(st.name, st.url, st.homepage, st.favicon),
                              ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Tap a station to listen first. Stations come from radio-browser.info.',
                        style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
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
