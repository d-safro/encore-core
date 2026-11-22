import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../data/device_playlists.dart';
import '../data/models.dart';
import '../data/updates.dart' show openUrl;
import '../playback/handler.dart';
import 'actions.dart';
import 'widgets.dart';

/// Add songs (files on this device and server songs alike) to a playlist kept on this device.
Future<void> addToDevicePlaylist(BuildContext context, WidgetRef ref, List<Song> songs) async {
  final lists = ref.read(devicePlaylistsProvider);
  final pick = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(title: Text('Add to a playlist on this ${isDesktop ? 'computer' : 'device'}',
              style: Theme.of(ctx).textTheme.titleMedium)),
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('New playlist'),
            onTap: () => Navigator.pop(ctx, ''),
          ),
          for (final p in lists)
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: Text(p.name),
              subtitle: Text(nSongs(p.songs.length)),
              onTap: () => Navigator.pop(ctx, p.id),
            ),
        ],
      ),
    ),
  );
  if (pick == null || !context.mounted) return;
  final n = ref.read(devicePlaylistsProvider.notifier);
  if (pick.isEmpty) {
    final name = await askText(context, 'New playlist', 'Name');
    if (name == null) return;
    final p = n.create(name, songs);
    if (context.mounted) toast(context, 'Made "${p.name}" with ${nSongs(songs.length)}');
    return;
  }
  final added = n.add(pick, songs);
  final name = ref.read(devicePlaylistsProvider).firstWhere((p) => p.id == pick).name;
  if (context.mounted) toast(context, added == 0 ? 'Already in "$name"' : 'Added ${nSongs(added)} to "$name"');
}

/// A file on this device: its own menu (no server actions: it isn't on the server).
Future<void> showLocalSongMenu(BuildContext context, WidgetRef ref, Song song, {int? queueIndex}) =>
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (ctx) {
        void close() => Navigator.pop(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text([song.artist, song.album, 'on this ${isDesktop ? 'computer' : 'device'}']
                    .where((x) => x.isNotEmpty)
                    .join(' · ')),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.playlist_play),
                title: const Text('Play next'),
                onTap: () {
                  close();
                  audioHandler.playNext([song]);
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const Text('Add to queue'),
                onTap: () {
                  close();
                  audioHandler.addLast([song]);
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
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: Text('Add to a playlist on this ${isDesktop ? 'computer' : 'device'}'),
                onTap: () {
                  close();
                  addToDevicePlaylist(context, ref, [song]);
                },
              ),
              if (isDesktop && !song.path.contains('://'))
                ListTile(
                  leading: const Icon(Icons.folder_open_rounded),
                  title: const Text('Show in folder'),
                  subtitle: Text(song.path, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    close();
                    openUrl(Uri.file(song.path).resolve('.').toString());
                  },
                ),
            ],
          ),
        );
      },
    );

/// A playlist kept on this device: play, shuffle, reorder, remove, rename, delete.
class DevicePlaylistScreen extends ConsumerWidget {
  const DevicePlaylistScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(devicePlaylistsProvider).where((x) => x.id == id).firstOrNull;
    if (p == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('This playlist is gone')));
    final n = ref.read(devicePlaylistsProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final name = await askText(context, 'Rename', 'Name', initial: p.name);
              if (name != null && name.trim().isNotEmpty) n.rename(id, name);
            },
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirm(context, 'Delete "${p.name}"?', 'Only the playlist goes: the songs stay.')) {
                n.delete(id);
                if (context.mounted) context.pop();
              }
            },
          ),
        ],
      ),
      body: p.songs.isEmpty
          ? const Center(child: Text('Add songs from any song\'s menu'))
          : Column(
              children: [
                PlayButtons(
                  source: 'device:$id',
                  onPlay: () async => audioHandler.playSongs(p.songs),
                  onShuffle: () async => audioHandler.playSongs(p.songs, shuffle: true),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    itemCount: p.songs.length,
                    onReorder: (a, b) => n.move(id, a, b),
                    itemBuilder: (_, i) => Dismissible(
                      key: ValueKey('${p.songs[i].id}-$i'),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => n.removeAt(id, i),
                      background: Container(
                        color: Theme.of(context).colorScheme.errorContainer,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        child: const Icon(Icons.delete_outline),
                      ),
                      child: SongTile(p.songs[i], list: p.songs, index: i),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
