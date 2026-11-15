import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';

import '../../data/account.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../state.dart';
import '../widgets.dart';
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
  });
  final String cover, title, artist, album;
  final List<Widget> lines;
  final bool circle;
  final IconData icon;
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
                child: Container(
                  decoration: BoxDecoration(
                    shape: circle ? BoxShape.circle : BoxShape.rectangle,
                    borderRadius: circle ? null : BorderRadius.circular(18),
                    boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 40, offset: Offset(0, 16))],
                  ),
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
  @override
  Widget build(BuildContext context) {
    final album = ref.watch(albumProvider(widget.id));
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent, forceMaterialTransparency: true),
      body: AsyncView(album, (Album a) {
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
          children.add(SongTile(s, list: playable, showTrack: true));
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
                        a.isLookup ? 'This album isn\'t in your library' : '$missing songs aren\'t in your library',
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
                  onPlay: () => audioHandler.playSongs(playable),
                  onShuffle: () => audioHandler.playSongs(playable, shuffle: true),
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
                    IconButton(
                      icon: const Icon(Icons.more_vert_rounded),
                      onPressed: () => showCollectionMenu(context, ref, a.name, () async => playable),
                    ),
                  ],
                ),
              ...children,
              const SizedBox(height: 24),
            ],
          ),
        );
      }, onRetry: () => ref.invalidate(albumProvider(widget.id))),
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
  bool _bioOpen = false;

  @override
  Widget build(BuildContext context) {
    final artist = ref.watch(artistProvider(widget.id));
    final info = ref.watch(artistInfoProvider(widget.id));
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent, forceMaterialTransparency: true),
      body: AsyncView(artist, (Artist a) {
        final own = a.albums.where((x) => !x.isLookup).toList()..sort((x, y) => (y.year ?? 0).compareTo(x.year ?? 0));
        final missing = a.albums.where((x) => x.isLookup).toList();
        pollIf(
          missing.any((x) => x.lookup == LookupState.downloading),
          () => ref.invalidate(artistProvider(widget.id)),
        );
        final top = ref.watch(topSongsProvider(a.name)).value ?? const <Song>[];
        final topOwn = top.where((s) => !s.isLookup).take(5).toList();
        final bio = info.value?.biography ?? '';
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
                  '${own.length} albums${missing.isNotEmpty ? ' · ${missing.length} more you don\'t have' : ''}',
                  style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            PlayButtons(
              onPlay: () async => audioHandler.playSongs(await allSongs()),
              onShuffle: () async => audioHandler.playSongs(await allSongs(), shuffle: true),
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
                  tooltip: 'Artist radio',
                  icon: const Icon(Icons.radio_rounded),
                  onPressed: () async {
                    final songs = topOwn.isNotEmpty ? topOwn : (await allSongs());
                    if (songs.isNotEmpty && context.mounted) openSongRadio(context, songs.first);
                  },
                ),
              ],
            ),
            if (topOwn.isNotEmpty) ...[
              const SectionTitle('Popular'),
              for (var i = 0; i < topOwn.length; i++) SongTile(topOwn[i], list: topOwn, index: i),
            ],
            if (own.isNotEmpty)
              Shelf(
                title: 'Albums',
                height: 220,
                children: [for (final al in own) AlbumCard(al, showArtist: false, showYear: true)],
              ),
            if (missing.isNotEmpty)
              Shelf(
                title: 'Not in your library',
                height: 220,
                children: [for (final al in missing) AlbumCard(al, showArtist: false, showYear: true)],
              ),
            if (bio.isNotEmpty) ...[
              const SectionTitle('About'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: InkWell(
                  onTap: () => setState(() => _bioOpen = !_bioOpen),
                  child: Text(bio, maxLines: _bioOpen ? null : 4, overflow: _bioOpen ? null : TextOverflow.ellipsis),
                ),
              ),
            ],
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
      }, onRetry: () => ref.invalidate(artistProvider(widget.id))),
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
    setState(() {
      _editing = false;
      _edit = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pl = ref.watch(playlistProvider(widget.id));
    final online = ref.watch(repoProvider).online;
    return Scaffold(
      extendBodyBehindAppBar: !_editing,
      appBar: AppBar(
        backgroundColor: _editing ? null : Colors.transparent,
        forceMaterialTransparency: !_editing,
        title: _editing ? const Text('Edit playlist') : null,
        actions: [
          if (_editing)
            TextButton(onPressed: _save, child: const Text('Save'))
          else if (pl.hasValue && online)
            PopupMenuButton<String>(
              onSelected: (v) async {
                final p = pl.value!;
                final c = ref.read(clientProvider)!;
                switch (v) {
                  case 'edit':
                    setState(() {
                      _editing = true;
                      _edit = [...p.songs];
                    });
                  case 'rename':
                    final n = await askText(context, 'Rename playlist', 'Name', initial: p.name);
                    if (n != null && n.isNotEmpty) {
                      await c.updatePlaylist(p.id, name: n);
                      ref.invalidate(playlistProvider(widget.id));
                      ref.invalidate(playlistsProvider);
                    }
                  case 'menu':
                    showCollectionMenu(context, ref, p.name, () async => p.songs);
                  case 'delete':
                    if (await confirm(context, 'Delete "${p.name}"?', 'This deletes the playlist on your server.')) {
                      await c.deletePlaylist(p.id);
                      ref.invalidate(playlistsProvider);
                      if (context.mounted) context.pop();
                    }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'menu', child: Text('Queue / download…')),
                PopupMenuItem(value: 'edit', child: Text('Reorder / remove songs')),
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
      body: AsyncView(pl, (Playlist p) {
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
        pollIf(pending > 0, () => ref.invalidate(playlistProvider(widget.id)));
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(playlistProvider(widget.id)),
          child: ListView(
            children: [
              _Header(
                cover: p.coverArt,
                title: p.name,
                icon: Icons.queue_music_rounded,
                lines: [
                  if (p.comment.isNotEmpty) Text(p.comment, style: Theme.of(context).textTheme.bodyMedium),
                  Text(
                    '${p.songs.length} songs · ${formatDuration(p.duration ?? p.songs.fold<int>(0, (n, s) => n + (s.duration ?? 0)))}'
                    '${pending > 0 ? ' · $pending waiting to download' : ''}',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              if (songs.isNotEmpty)
                PlayButtons(
                  onPlay: () => audioHandler.playSongs(songs),
                  onShuffle: () => audioHandler.playSongs(songs, shuffle: true),
                  leading: [DownloadToggle(pinKey: 'playlist:${p.id}', songs: () async => songs)],
                ),
              for (var i = 0; i < p.songs.length; i++) SongTile(p.songs[i], list: songs),
              const SizedBox(height: 24),
            ],
          ),
        );
      }, onRetry: () => ref.invalidate(playlistProvider(widget.id))),
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
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        children: [
          PlayButtons(
            onPlay: () async =>
                audioHandler.playSongs(await ref.read(repoProvider).randomSongs(size: 200, genre: name)),
            onShuffle: () async =>
                audioHandler.playSongs(await ref.read(repoProvider).randomSongs(size: 200, genre: name), shuffle: true),
          ),
          albums.when(
            data: (l) => Shelf(title: 'Albums', children: [for (final a in l.where((a) => !a.isLookup)) AlbumCard(a)]),
            loading: () => const SizedBox(height: 40),
            error: (_, _) => const SizedBox.shrink(),
          ),
          ...switch (songs) {
            AsyncData(:final value) => [
              SectionTitle('Songs (${value.length})'),
              for (var i = 0; i < value.length; i++) SongTile(value[i], list: value, index: i),
            ],
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
    final c = ref.read(clientProvider)!;
    _future = widget.id == null ? c.indexes() : c.directory(widget.id!);
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
          return ListView(
            children: [
              if (songs.isNotEmpty)
                PlayButtons(
                  onPlay: () => audioHandler.playSongs(songs),
                  onShuffle: () => audioHandler.playSongs(songs, shuffle: true),
                ),
              for (final e in entries.where((e) => e.isDir))
                ListTile(
                  leading: e.coverArt.isNotEmpty ? Cover(e.coverArt, size: 44) : const Icon(Icons.folder_outlined),
                  title: Text(e.name),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => FoldersScreen(id: e.id, title: e.name),
                    ),
                  ),
                ),
              for (var i = 0; i < songs.length; i++) SongTile(songs[i], list: songs, index: i),
            ],
          );
        },
      ),
    );
  }
}

// ── Internet radio (stations saved in Navidrome) ──
class RadioScreen extends ConsumerWidget {
  const RadioScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Internet radio')),
      body: AsyncView(ref.watch(radiosProvider), (List<InternetRadio> list) {
        if (list.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No radio stations yet. Add them in Navidrome (Settings → Radio).',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView(
          children: [
            for (final r in list)
              ListTile(
                leading: const Icon(Icons.radio),
                title: Text(r.name),
                subtitle: Text(
                  r.homePageUrl.isNotEmpty ? r.homePageUrl : r.streamUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  await audioHandler.clearQueue();
                  await audioHandler.player.setAudioSource(
                    AudioSource.uri(
                      Uri.parse(r.streamUrl),
                      tag: MediaItem(id: 'radio-${r.id}', title: r.name, artist: 'Internet radio'),
                    ),
                  );
                  audioHandler.mediaItem.add(MediaItem(id: 'radio-${r.id}', title: r.name, artist: 'Internet radio'));
                  audioHandler.player.play();
                },
              ),
          ],
        );
      }),
    );
  }
}
