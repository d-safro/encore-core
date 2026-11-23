import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../core/platform.dart';
import '../../data/devices.dart';
import '../../data/elsewhere.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../devices_sheet.dart' show deviceIcon, showRemoteControl;
import '../sheets.dart';
import '../widgets.dart';

/// Home's "Now playing elsewhere": your other devices playing now, and other people on the server (when it shares
/// that). Hidden when nothing plays elsewhere. Tap one to see the song and play it here.
class NowPlayingElsewhereShelf extends ConsumerWidget {
  const NowPlayingElsewhereShelf({super.key, this.phone});

  /// The phone's layout (null: as this device is).
  final bool? phone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(playingElsewhereProvider);
    if (items.isEmpty) return const SizedBox.shrink();
    final mine = items.where((i) => i.mine).length;
    final subtitle = mine == items.length
        ? 'On your other ${mine == 1 ? 'device' : 'devices'}'
        : mine == 0
        ? 'Others on this server'
        : 'Your devices and others on this server';
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(header: true, child: SectionTitle('Now playing elsewhere', subtitle: subtitle)),
          LayoutBuilder(
            builder: (context, box) {
              // a phone: a row to scroll sideways; a tablet or the desktop: a grid, more across as it widens
              if ((phone ?? !isDesktop) && box.maxWidth < 640) {
                final w = (box.maxWidth * 0.82).clamp(220.0, 320.0);
                return SizedBox(
                  height: 64,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => SizedBox(width: items.length == 1 ? box.maxWidth - 32 : w, child: ElsewhereTile(items[i])),
                  ),
                );
              }
              final columns = box.maxWidth >= 1200 ? 4 : (box.maxWidth >= 900 ? 3 : (box.maxWidth >= 420 ? 2 : 1));
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GridView(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    mainAxisExtent: 64,
                  ),
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [for (final it in items.take(columns * 2)) ElsewhereTile(it)],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// One song playing elsewhere: its cover, its title, and where or who.
class ElsewhereTile extends StatelessWidget {
  const ElsewhereTile(this.item, {super.key});
  final PlayingElsewhere item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final look = AppLook.of(context);
    final s = item.song;
    return Semantics(
      button: true,
      label: item.spoken,
      hint: 'Shows the song, to play it here',
      excludeSemantics: true,
      child: Tooltip(
        message: '${s.title}${s.artist.isEmpty ? '' : ' · ${s.artist}'}\n${item.where}',
        waitDuration: const Duration(milliseconds: 600),
        child: Material(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(look.r(10)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => showElsewhereSheet(context, item),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  Cover(s.coverArt, size: 52, radius: 8, artist: s.artist, album: s.album),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        if (s.artist.isNotEmpty)
                          Text(
                            s.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        Row(
                          children: [
                            Icon(
                              item.mine ? deviceIcon(item.device!.kind) : Icons.person_outline_rounded,
                              size: 13,
                              color: cs.primary,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                item.where,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.labelSmall?.copyWith(color: cs.primary),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The song playing elsewhere: play it here (from one of your devices: take over where it is, and pause it there),
/// control that device, or go to its album or artist.
Future<void> showElsewhereSheet(BuildContext context, PlayingElsewhere item) => showAppSheet(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => _ElsewhereSheet(item),
);

class _ElsewhereSheet extends ConsumerWidget {
  const _ElsewhereSheet(this.item);
  final PlayingElsewhere item;

  /// The song as the server has it (a device only says its title, artist and album): for its album and artist.
  Future<Song?> _full(WidgetRef ref) async {
    final s = item.song;
    if (s.albumId.isNotEmpty || s.artistId.isNotEmpty) return s;
    final got = await ref.read(repoProvider).resolveSongs([s.id]);
    return got.firstOrNull;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final s = item.song;
    final d = item.device;
    final p = item.person;
    final where = d != null
        ? 'Playing on your ${d.name}'
        : [
            '${p!.user} is listening${p.player.isEmpty ? '' : ' on ${p.player}'}',
            if (p.minutesAgo > 0) '${p.minutesAgo} min ago',
          ].join(' · ');

    Future<void> act(Future<bool> Function() f, String failed) async {
      final ok = await f();
      if (!context.mounted) return;
      if (ok) {
        Navigator.pop(context);
      } else {
        toast(context, failed);
      }
    }

    Future<bool> playHere() async {
      if (d != null) return ref.read(devicesProvider.notifier).playHere(d);
      final got = await ref.read(repoProvider).resolveSongs([s.id]);
      if (got.isEmpty) return false;
      await audioHandler.playSongs(got);
      return true;
    }

    Future<bool> playNext() async {
      final got = await ref.read(repoProvider).resolveSongs([s.id]);
      if (got.isEmpty) return false;
      await audioHandler.playNext(got);
      return true;
    }

    Future<void> go(String Function(Song) path, bool Function(Song) has) async {
      final full = await _full(ref);
      if (!context.mounted) return;
      if (full == null || !has(full)) {
        toast(context, "Couldn't find it on the server");
        return;
      }
      final router = GoRouter.of(context);
      Navigator.pop(context);
      router.push(path(full));
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Cover(s.coverArt, size: 72, radius: 10, artist: s.artist, album: s.album),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Semantics(
                      container: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.titleMedium),
                          if (s.artist.isNotEmpty || s.album.isNotEmpty)
                            Text(
                              [s.artist, s.album].where((x) => x.isNotEmpty).join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          const SizedBox(height: 4),
                          Text(where, style: t.labelMedium?.copyWith(color: cs.primary)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Play here'),
              subtitle: Text(d != null ? 'From where it is, and pause it on ${d.name}' : 'Play this song on this device'),
              onTap: () => act(playHere, d != null ? "Couldn't take over what's playing there" : "Couldn't play it here"),
            ),
            ListTile(
              leading: const Icon(Icons.queue_play_next_rounded),
              title: const Text('Play next'),
              onTap: () => act(playNext, "Couldn't find it on the server"),
            ),
            if (d != null)
              ListTile(
                leading: const Icon(Icons.settings_remote_rounded),
                title: Text('Control ${d.name}'),
                onTap: () {
                  Navigator.pop(context);
                  showRemoteControl(context, d.id);
                },
              ),
            ListTile(
              leading: const Icon(Icons.album_outlined),
              title: const Text('Go to album'),
              onTap: () => go((f) => '/album/${f.albumId}', (f) => f.albumId.isNotEmpty),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline_rounded),
              title: const Text('Go to artist'),
              onTap: () => go((f) => '/artist/${f.artistId}', (f) => f.artistId.isNotEmpty),
            ),
          ],
        ),
      ),
    );
  }
}
