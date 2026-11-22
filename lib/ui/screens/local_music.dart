import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../data/local_files.dart';
import '../../playback/handler.dart';
import '../../data/device_playlists.dart';
import '../widgets.dart';

/// Library > On this device: music files on this phone or computer that aren't in your server's library
/// (local_files.dart). They play offline, never go to the server, and aren't scrobbled.
class LocalMusicScreen extends ConsumerStatefulWidget {
  const LocalMusicScreen({super.key});
  @override
  ConsumerState<LocalMusicScreen> createState() => _LocalMusicScreenState();
}

class _LocalMusicScreenState extends ConsumerState<LocalMusicScreen> {
  String _filter = '';

  @override
  void initState() {
    super.initState();
    // the first time it's opened: ask for the permission (Android) and look
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final l = ref.read(localLibraryProvider);
      if (!l.allowed || (l.loaded && l.tracks.isEmpty)) ref.read(localLibraryProvider.notifier).refresh(ask: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = ref.watch(localLibraryProvider);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final songs = _filter.isEmpty ? l.songs : l.search(_filter);
    final where = isDesktop ? 'this computer' : 'this phone';
    return Scaffold(
      appBar: AppBar(
        title: Text(isDesktop ? 'On this computer' : 'On this device'),
        actions: [
          IconButton(
            tooltip: 'Look again',
            icon: l.scanning
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
            onPressed: l.scanning ? null : () => ref.read(localLibraryProvider.notifier).refresh(ask: true),
          ),
          if (isDesktop)
            IconButton(
              tooltip: 'Folders to look in',
              icon: const Icon(Icons.folder_open_rounded),
              onPressed: () => context.push('/settings'),
            ),
        ],
      ),
      body: !l.allowed
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.library_music_outlined, size: 48),
                    const SizedBox(height: 12),
                    Text('Encore needs to see the music on $where', style: t.titleMedium, textAlign: TextAlign.center),
                    const SizedBox(height: 6),
                    Text(
                      'It stays on $where: nothing is uploaded or scrobbled.',
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => ref.read(localLibraryProvider.notifier).refresh(ask: true),
                      child: const Text('Allow'),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              itemCount: songs.length + 2,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l.scanning && l.tracks.isEmpty
                              ? 'Looking for music on $where…'
                              : '${l.tracks.length} song${l.tracks.length == 1 ? '' : 's'} on $where, not in your server '
                                    'library. They play offline and stay private.',
                          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                        // playlists kept here: files on this device and server songs together
                        for (final pl in ref.watch(devicePlaylistsProvider))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.queue_music_rounded),
                            title: Text(pl.name),
                            subtitle: Text('${pl.songs.length} song${pl.songs.length == 1 ? '' : 's'}'),
                            onTap: () => context.push('/local/playlist/${pl.id}'),
                          ),
                        if (l.tracks.isNotEmpty && isDesktop)
                          // desktop: the play and shuffle buttons every other song list has, the filter beside them
                          PlayButtons(
                            onPlay: () => audioHandler.playSongs(songs, source: 'local'),
                            onShuffle: () => audioHandler.playSongs(songs, shuffle: true, source: 'local'),
                            leading: [
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 320),
                                child: SizedBox(
                                  height: 40,
                                  child: TextField(
                                    decoration: InputDecoration(
                                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                                      hintText: 'Filter',
                                      isDense: true,
                                      contentPadding: EdgeInsets.zero,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(20),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                    onChanged: (v) => setState(() => _filter = v.trim()),
                                  ),
                                ),
                              ),
                            ],
                          )
                        else if (l.tracks.isNotEmpty)
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  decoration: const InputDecoration(
                                    prefixIcon: Icon(Icons.search_rounded),
                                    hintText: 'Filter',
                                  ),
                                  onChanged: (v) => setState(() => _filter = v.trim()),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.tonalIcon(
                                icon: const Icon(Icons.shuffle_rounded),
                                label: const Text('Shuffle'),
                                onPressed: songs.isEmpty ? null : () => audioHandler.playSongs(songs, shuffle: true),
                              ),
                            ],
                          ),
                      ],
                    ),
                  );
                }
                if (i == songs.length + 1) return const SizedBox(height: 32);
                return SongTile(songs[i - 1], list: songs, index: i - 1);
              },
            ),
    );
  }
}

/// The Library entry (top of the Songs tab).
class LocalMusicTile extends ConsumerWidget {
  const LocalMusicTile({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final l = ref.watch(localLibraryProvider);
    return ListTile(
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: cs.secondaryContainer,
        child: Icon(isDesktop ? Icons.computer_rounded : Icons.smartphone_rounded, color: cs.onSecondaryContainer),
      ),
      title: Text(isDesktop ? 'On this computer' : 'On this device'),
      subtitle: Text(
        l.tracks.isEmpty
            ? 'Music files that aren\'t on your server'
            : '${l.tracks.length} song${l.tracks.length == 1 ? '' : 's'} · play offline, stay private',
      ),
      onTap: () => context.push('/local'),
    );
  }
}
