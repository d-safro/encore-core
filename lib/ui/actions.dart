import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';
import '../core/platform.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/account.dart';
import '../data/library.dart';
import '../data/library_pins.dart';
import '../data/models.dart';
import '../data/playlist_add.dart';
import '../data/share_links.dart';
import '../playback/handler.dart';
import 'screens/radio.dart';
import 'state.dart';
import 'widgets.dart' show nSongs;

void toast(BuildContext context, String text) {
  if (!context.mounted) return; // the screen was closed while waiting
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
}

/// Make a song.link-style page for something and open Android's share sheet with it.
Future<void> shareLink(BuildContext context, String label, Future<String?> Function() make) async {
  toast(context, 'Making a link…');
  try {
    final url = await make();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (url == null) {
      toast(context, "Couldn't find $label on streaming services");
      return;
    }
    if (isDesktop) {
      // no share sheet on the desktop: the link goes on the clipboard
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) toast(context, 'Link copied');
      return;
    }
    await SharePlus.instance.share(ShareParams(text: '$label\n$url', subject: label));
  } catch (e) {
    if (context.mounted) toast(context, "Couldn't make a link: $e");
  }
}

/// Heart / unheart a song. On a song you don't have yet (⬇), the heart asks the server to download it.
Future<Song> toggleStarSong(BuildContext context, WidgetRef ref, Song s) async {
  final c = ref.read(clientProvider);
  if (c == null) return s;
  final next = !(ref.read(heartsProvider)[s.id] ?? s.starred);
  try {
    next ? await c.star(id: s.id) : await c.unstar(id: s.id);
    ref.read(heartsProvider.notifier).set(s.id, next);
    final updated = s.copyWith(starred: next);
    audioHandler.updateSong(updated);
    ref.read(dbProvider).updateSong(updated);
    ref.invalidate(starredProvider);
    if (s.isLookup && next) {
      toast(context, 'Keeping "${s.title}": your server downloads it to your library');
    } else if (next && audioHandler.isOnTrial(s.id)) {
      audioHandler.kept(s.id);
      toast(context, 'Kept "${s.title}" in your library for good');
    }
    return updated;
  } catch (e) {
    toast(context, 'Couldn\'t update: $e');
    return s;
  }
}

Future<void> toggleStarAlbum(BuildContext context, WidgetRef ref, Album a) async {
  final c = ref.read(clientProvider);
  if (c == null) return;
  try {
    a.starred ? await c.unstar(albumId: a.id) : await c.star(albumId: a.id);
    ref.invalidate(albumProvider(a.id));
    ref.invalidate(starredProvider);
    if (a.isLookup && !a.starred) toast(context, 'Downloading "${a.name}" to your library');
  } catch (e) {
    toast(context, 'Couldn\'t update: $e');
  }
}

Future<void> toggleStarArtist(BuildContext context, WidgetRef ref, Artist a) async {
  final c = ref.read(clientProvider);
  if (c == null) return;
  try {
    a.starred ? await c.unstar(artistId: a.id) : await c.star(artistId: a.id);
    ref.invalidate(artistProvider(a.id));
  } catch (e) {
    toast(context, 'Couldn\'t update: $e');
  }
}

Future<void> rateSong(BuildContext context, WidgetRef ref, Song s) async {
  final rating = await showDialog<int>(
    context: context,
    builder: (ctx) {
      var r = s.userRating ?? 0;
      return StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Rating'),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  tooltip: '$i star${i == 1 ? '' : 's'}',
                  iconSize: 36,
                  icon: Icon(i <= r ? Icons.star_rounded : Icons.star_outline_rounded),
                  onPressed: () => set(() => r = r == i ? 0 : i),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, r), child: const Text('Save')),
          ],
        ),
      );
    },
  );
  if (rating == null) return;
  try {
    await ref.read(clientProvider)!.setRating(s.id, rating);
    audioHandler.updateSong(s.copyWith(userRating: rating));
  } catch (e) {
    toast(context, 'Couldn\'t save the rating: $e');
  }
}

Future<void> addToPlaylist(BuildContext context, WidgetRef ref, List<Song> songs) async {
  final c = ref.read(clientProvider);
  if (c == null || songs.isEmpty) return;
  final lists = await ref.read(repoProvider).playlists();
  if (!context.mounted) return;
  final choice = await showModalBottomSheet<Object>(
    useRootNavigator: true,
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New playlist'),
            onTap: () => Navigator.pop(ctx, 'new'),
          ),
          for (final p in lists)
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(p.name),
              subtitle: Text(nSongs(p.songCount ?? 0)),
              onTap: () => Navigator.pop(ctx, p),
            ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  // ⬇ songs (not in your library) are downloaded by the server first and only then join the playlist; the
  // server lists them at the end until they arrive. That can't be undone, so ask first when there are some.
  var wanted = songs.where((s) => s.isLookup).toList();
  final own = songs.where((s) => !s.isLookup).toList();
  if (wanted.isNotEmpty && songs.length > 1) {
    final get = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Some songs aren\'t in your library'),
        content: Text(
          '${wanted.length == 1 ? '1 song isn\'t' : '${wanted.length} songs aren\'t'} in your library yet. '
          'Your server can download ${wanted.length == 1 ? 'it' : 'them'} into your library and then add '
          '${wanted.length == 1 ? 'it' : 'them'} to the playlist. Undo can\'t take back downloads.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          if (own.isNotEmpty)
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Only the ${nSongs(own.length)} I have')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Get them too')),
        ],
      ),
    );
    if (get == null || !context.mounted) return;
    if (!get) wanted = [];
  }
  final ids = own.map((s) => s.id).toList();
  final what = songs.length == 1 ? '"${songs.first.title}"' : nSongs(ids.length + wanted.length);
  final later = wanted.isEmpty || songs.length == 1 ? '' : ' (${nSongs(wanted.length)} once they\'re downloaded)';
  try {
    if (choice == 'new') {
      final name = await askText(context, 'New playlist', 'Name');
      if (name == null || name.isEmpty) return;
      final made = await c.createPlaylist(name, [...ids, ...wanted.map((s) => s.id)]);
      ref.invalidate(playlistsProvider);
      if (context.mounted) {
        undoToast(context, 'Created "$name"$later', () async {
          await c.deletePlaylist(made.id);
          ref.invalidate(playlistsProvider);
        });
      }
    } else if (choice is Playlist) {
      // only songs really in the playlist count (the server appends ⬇ ones still on their way)
      List<String> real(Playlist p) => [for (final s in p.songs) if (!s.id.startsWith('dz-')) s.id];
      final before = real(await c.playlist(choice.id));
      final dupes = alreadyIn(before, ids);
      var send = ids;
      if (dupes.isNotEmpty) {
        if (!context.mounted) return;
        final all = dupes.length == ids.length && wanted.isEmpty;
        final skip = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Already in the playlist'),
            content: Text(
              all
                  ? (ids.length == 1
                        ? 'This song is already in ${choice.name}.'
                        : 'All of these songs are already in ${choice.name}.')
                  : '${dupes.length == 1 ? '1 of these songs is' : '${dupes.length} of these songs are'} '
                        'already in ${choice.name}.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Add anyway')),
              if (!all) FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Skip them')),
            ],
          ),
        );
        if (skip == null) return;
        send = toSend(before, ids, skipDuplicates: skip);
      }
      if (send.isEmpty && wanted.isEmpty) return;
      await c.updatePlaylist(choice.id, add: [...send, ...wanted.map((s) => s.id)]);
      ref.invalidate(playlistProvider(choice.id));
      ref.invalidate(playlistsProvider);
      if (!context.mounted) return;
      final added = send.length == ids.length ? what : nSongs(send.length + wanted.length);
      if (send.isEmpty) {
        toast(context, 'Added $added to ${choice.name}$later');
        return;
      }
      undoToast(context, 'Added $added to ${choice.name}$later', () async {
        final idx = undoIndexes(real(await c.playlist(choice.id)), before.length, send);
        if (idx == null) throw 'the playlist changed since';
        await c.updatePlaylist(choice.id, removeIndexes: idx);
        ref.invalidate(playlistProvider(choice.id));
        ref.invalidate(playlistsProvider);
      });
    }
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t add: $e');
  }
}

/// A toast with an Undo button. [undo] runs if it's pressed; a failure shows as another toast.
void undoToast(BuildContext context, String text, Future<void> Function() undo) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            try {
              await undo();
              messenger.showSnackBar(
                const SnackBar(content: Text('Undone'), behavior: SnackBarBehavior.floating),
              );
            } catch (e) {
              messenger.showSnackBar(
                SnackBar(content: Text('Couldn\'t undo: $e'), behavior: SnackBarBehavior.floating),
              );
            }
          },
        ),
      ),
    );
}

Future<String?> askText(BuildContext context, String title, String label, {String initial = ''}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String text, {String ok = 'Delete'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    ) ??
    false;

/// Long-press / ⋮ menu for a song.
Future<void> showSongMenu(
  BuildContext context,
  WidgetRef ref,
  Song song, {
  List<Song>? context_,
  int? queueIndex,
}) async {
  final downloads = ref.read(downloadsProvider);
  final have = downloads.files.containsKey(song.id);
  final online = ref.read(repoProvider).online;
  await showModalBottomSheet(
    context: context,
    showDragHandle: true,
    useRootNavigator: true, // above the mini player and the tab bar
    isScrollControlled: true,
    builder: (ctx) {
      void close() => Navigator.pop(ctx);
      final liked = ref.read(heartsProvider)[song.id] ?? song.starred;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${song.artist} · ${song.album}', maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const Divider(height: 1),
              if (song.isLookup && audioHandler.autoGet) ...[
                ListTile(
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: const Text('Play'),
                  subtitle: const Text('Your server gets it on trial; heart it to keep it'),
                  onTap: () {
                    close();
                    audioHandler.playSongs([song]);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_play),
                  title: const Text('Play next'),
                  onTap: () {
                    close();
                    audioHandler.playNext([song]);
                    toast(context, 'Playing next: ${song.title}');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: const Text('Add to queue'),
                  onTap: () {
                    close();
                    audioHandler.addLast([song]);
                    toast(context, 'Added to queue: ${song.title}');
                  },
                ),
                if (online)
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: const Text('Add to playlist'),
                    subtitle: const Text('Downloads it for good, then adds it to the playlist'),
                    onTap: () {
                      close();
                      addToPlaylist(context, ref, [song]);
                    },
                  ),
              ] else if (song.isLookup) ...[
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: const Text('Download to my library'),
                  subtitle: const Text('The server finds it on Soulseek and adds it'),
                  onTap: () {
                    close();
                    if (!(ref.read(heartsProvider)[song.id] ?? song.starred)) toggleStarSong(context, ref, song);
                  },
                ),
                if (online)
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: const Text('Add to playlist'),
                    subtitle: const Text('Downloads it, then adds it to the playlist'),
                    onTap: () {
                      close();
                      addToPlaylist(context, ref, [song]);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: const Text('Play preview'),
                  onTap: () {
                    close();
                    audioHandler.playSongs([song], allowLookup: true);
                  },
                ),
              ] else ...[
                if (online)
                  ListTile(
                    leading: const Icon(Icons.radio_rounded),
                    title: const Text('Song radio'),
                    subtitle: const Text('This song, then songs like it, without end'),
                    onTap: () {
                      close();
                      openSongRadio(context, song);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.playlist_play),
                  title: const Text('Play next'),
                  onTap: () {
                    close();
                    audioHandler.playNext([song]);
                    toast(context, 'Playing next: ${song.title}');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: const Text('Add to queue'),
                  onTap: () {
                    close();
                    audioHandler.addLast([song]);
                    toast(context, 'Added to queue: ${song.title}');
                  },
                ),
                if (online)
                  ListTile(
                    leading: const Icon(Icons.radio),
                    title: const Text('Instant mix'),
                    subtitle: const Text('Songs that sound like this one'),
                    onTap: () {
                      close();
                      audioHandler.instantMix(song);
                    },
                  ),
                if (online)
                  ListTile(
                    leading: const Icon(Icons.timeline),
                    title: const Text('Mix to another song…'),
                    subtitle: const Text('A path of songs from this sound to another'),
                    onTap: () {
                      close();
                      bridgeMix(context, ref, song);
                    },
                  ),
              ],
              if (online)
                ListTile(
                  leading: Icon(liked ? Icons.favorite : Icons.favorite_border),
                  title: Text(liked ? 'Remove from favourites' : 'Add to favourites'),
                  onTap: () {
                    close();
                    toggleStarSong(context, ref, song);
                  },
                ),
              if (online && !song.isLookup) ...[
                ListTile(
                  leading: const Icon(Icons.star_outline_rounded),
                  title: Text(
                    song.userRating != null && song.userRating! > 0 ? 'Rating: ${song.userRating}/5' : 'Rate',
                  ),
                  onTap: () {
                    close();
                    rateSong(context, ref, song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('Add to playlist'),
                  onTap: () {
                    close();
                    addToPlaylist(context, ref, [song]);
                  },
                ),
              ],
              if (!song.isLookup)
                ListTile(
                  leading: Icon(have ? Icons.delete_outline : Icons.offline_pin_outlined),
                  title: Text(have ? 'Remove download' : 'Download for offline'),
                  onTap: () {
                    close();
                    have
                        ? ref.read(downloadsProvider.notifier).remove([song.id])
                        : ref.read(downloadsProvider.notifier).download([song], manual: true);
                  },
                ),
              if (queueIndex != null)
                ListTile(
                  leading: const Icon(Icons.remove_circle_outline),
                  title: const Text('Remove from queue'),
                  onTap: () {
                    close();
                    audioHandler.removeQueueItemAt(queueIndex);
                  },
                ),
              if (song.albumId.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.album_outlined),
                  title: const Text('Go to album'),
                  onTap: () {
                    close();
                    context.push('/album/${song.albumId}');
                  },
                ),
              if (song.artistId.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('Go to artist'),
                  onTap: () {
                    close();
                    context.push('/artist/${song.artistId}');
                  },
                ),
              if (online)
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('Share'),
                  subtitle: const Text('A link that opens in any music app'),
                  onTap: () {
                    close();
                    shareLink(context, '${song.title} · ${song.artist}', () => songLink(song));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Details'),
                onTap: () {
                  close();
                  showSongInfo(context, song);
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

void showSongInfo(BuildContext context, Song s) {
  final rows = <(String, String)>[
    ('Title', s.title),
    ('Artist', s.artist),
    ('Album', s.album),
    if (s.track != null) ('Track', '${s.disc != null ? '${s.disc}-' : ''}${s.track}'),
    if (s.year != null) ('Year', '${s.year}'),
    if (s.genre.isNotEmpty) ('Genre', s.genre),
    ('Length', formatDuration(s.duration)),
    if (s.suffix.isNotEmpty) ('Format', '${s.suffix.toUpperCase()}${s.bitRate != null ? ' · ${s.bitRate} kbps' : ''}'),
    if (s.size != null) ('Size', '${(s.size! / 1048576).toStringAsFixed(1)} MB'),
    if (s.playCount != null) ('Plays', '${s.playCount}'),
    if (s.replayGain.trackGain != null) ('ReplayGain', '${s.replayGain.trackGain!.toStringAsFixed(1)} dB (track)'),
    if (s.path.isNotEmpty) ('File', s.path),
  ];
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Song details'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(k, style: Theme.of(ctx).textTheme.labelSmall),
                    SelectableText(v),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ),
  );
}

/// Menu for a whole collection (album, playlist, artist, genre).
Future<void> showCollectionMenu(
  BuildContext context,
  WidgetRef ref,
  String title,
  Future<List<Song>> Function() songs, {
  List<Widget> extra = const [],
  LibraryPin? pin, // offers "Pin to Library" for this playlist / album
}) async {
  final online = ref.read(repoProvider).online;
  final pinned = pin != null && ref.read(libraryPinsProvider.notifier).isPinned(pin.key);
  await showModalBottomSheet(
    context: context,
    showDragHandle: true,
    useRootNavigator: true, // above the mini player and the tab bar
    isScrollControlled: true,
    builder: (ctx) {
      Future<void> run(Future<void> Function(List<Song>) f) async {
        Navigator.pop(ctx);
        await f(await songs());
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
              const Divider(height: 1),
              if (pin != null)
                ListTile(
                  leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
                  title: Text(pinned ? 'Unpin from Library' : 'Pin to Library'),
                  onTap: () {
                    Navigator.pop(ctx);
                    ref.read(libraryPinsProvider.notifier).toggle(pin);
                    toast(context, pinned ? 'Unpinned' : 'Pinned to the top of your Library');
                  },
                ),
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Play'),
                onTap: () => run(audioHandler.playSongs),
              ),
              ListTile(
                leading: const Icon(Icons.shuffle),
                title: const Text('Shuffle'),
                onTap: () => run((s) => audioHandler.playSongs(s, shuffle: true)),
              ),
              ListTile(
                leading: const Icon(Icons.playlist_play),
                title: const Text('Play next'),
                onTap: () => run(audioHandler.playNext),
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const Text('Add to queue'),
                onTap: () => run(audioHandler.addLast),
              ),
              if (online)
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('Add to playlist'),
                  onTap: () => run((s) => addToPlaylist(context, ref, s)),
                ),
              ListTile(
                leading: const Icon(Icons.offline_pin_outlined),
                title: const Text('Download for offline'),
                onTap: () => run((s) async {
                  await ref.read(downloadsProvider.notifier).download(s);
                  if (context.mounted) toast(context, 'Downloading ${nSongs(s.length)}');
                }),
              ),
              ...extra,
            ],
          ),
        ),
      );
    },
  );
}

/// Pick a second song, then play a gradual path of sound-alikes from [from] to it (AudioMuse on the server).
Future<void> bridgeMix(BuildContext context, WidgetRef ref, Song from) async {
  final to = await pickSong(context, ref, 'Mix towards…');
  if (to == null) return;
  final c = ref.read(clientProvider);
  if (c == null) return;
  if (context.mounted) toast(context, 'Building a path to "${to.title}"…');
  final path = await c.sonicPath(from.id, to.id, count: 20);
  if (path.isEmpty) {
    if (context.mounted) {
      toast(context, 'Your server can\'t build that path yet (are both songs analysed by AudioMuse?)');
    }
    return;
  }
  final ids = {from.id, to.id};
  await audioHandler.playSongs([from, ...path.where((s) => ids.add(s.id) && !s.isLookup), to]);
}

/// A small search dialog that returns one song from the library.
Future<Song?> pickSong(BuildContext context, WidgetRef ref, String title) {
  return showModalBottomSheet<Song>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      var results = <Song>[];
      var seq = 0;
      return StatefulBuilder(
        builder: (ctx, set) {
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
            child: SizedBox(
              height: MediaQuery.sizeOf(ctx).height * 0.75,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      autofocus: true,
                      decoration: InputDecoration(labelText: title, prefixIcon: const Icon(Icons.search)),
                      onChanged: (q) async {
                        final my = ++seq;
                        if (q.trim().length < 2) return set(() => results = []);
                        final r = await ref.read(repoProvider).search(q.trim());
                        if (my == seq) set(() => results = r.songs.where((s) => !s.isLookup).toList());
                      },
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final s in results)
                          ListTile(
                            title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(s.artist, maxLines: 1),
                            onTap: () => Navigator.pop(ctx, s),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
