import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../data/account.dart';
import '../data/models.dart';
import 'actions.dart' show confirm, toast;
import 'screens/jam.dart' show QrView;
import 'sheets.dart';

/// Collaborative playlists: a link (like Jam's) that lets friends add songs from your library to this
/// playlist on a web page, and take out the ones they added. Made by the server (music-lookup's collab.py)
/// on Jam's public address, so it needs JAM_PUBLIC_URL (Tailscale Funnel) to work outside your home.
class PlaylistShare {
  const PlaylistShare({this.url = '', this.added = const [], this.error});
  final String url;
  final List<(String, String)> added; // song id, who added it
  final String? error;

  factory PlaylistShare.fromJson(Map<String, dynamic> j) => PlaylistShare(
    url: '${j['url'] ?? ''}',
    added: [
      for (final a in (j['added'] as List? ?? const []))
        if (a is Map) ('${a['id'] ?? ''}', '${a['by'] ?? ''}'),
    ],
    error: j['error'] as String?,
  );
}

Future<void> showInviteToEdit(BuildContext context, Playlist p) => showAppSheet(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => _InviteSheet(p),
);

class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet(this.p);
  final Playlist p;
  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  late final Future<PlaylistShare> _share = _start();

  Future<PlaylistShare> _start() async {
    final c = ref.read(clientProvider);
    if (c == null) throw 'Needs your server';
    final r = await c.call('playlistShareStart', {'id': widget.p.id});
    return PlaylistShare.fromJson((r['playlistShare'] as Map?)?.cast<String, dynamic>() ?? const {});
  }

  Future<void> _stop() async {
    if (!await confirm(context, 'Stop the link?', 'Friends can\'t add songs with it any more. What they added stays.',
        ok: 'Stop')) {
      return;
    }
    try {
      await ref.read(clientProvider)?.call('playlistShareEnd', {'id': widget.p.id});
    } catch (e) {
      if (mounted) toast(context, "Couldn't stop the link: $e"); // it still works: say so, and stay
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final names = {for (final s in widget.p.songs) s.id: s.title};
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: FutureBuilder<PlaylistShare>(
          future: _share,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
            }
            final s = snap.data;
            final problem = snap.hasError
                ? '${snap.error}'.contains('70') || '${snap.error}'.contains('404')
                    ? 'Your server can\'t share playlists for editing (it needs Conductor or music-lookup)'
                    : 'Couldn\'t make a link: ${snap.error}'
                : s?.error ?? (s!.url.isEmpty ? 'Your server has no public address for links (JAM_PUBLIC_URL)' : null);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Chorus · Invite to edit', style: t.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Anyone with this link can add songs from your library to "${widget.p.name}", and take out the ones '
                  'they added. Your songs stay.',
                  style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                if (problem != null)
                  ListTile(leading: const Icon(Icons.error_outline_rounded), title: Text(problem))
                else ...[
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                      child: SizedBox(width: 200, height: 200, child: QrView(s!.url)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(s.url, textAlign: TextAlign.center, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          icon: const Icon(Icons.share_rounded),
                          label: const Text('Share link'),
                          onPressed: () => SharePlus.instance.share(ShareParams(
                            text: 'Add songs to my playlist "${widget.p.name}": ${s.url}',
                            subject: widget.p.name,
                          )),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: 'Copy link',
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: s.url));
                          toast(context, 'Link copied');
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(icon: const Icon(Icons.link_off_rounded), label: const Text('Stop the link'), onPressed: _stop),
                  if (s.added.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('Added by friends', style: t.titleSmall),
                    for (final (id, by) in s.added.reversed.take(30))
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.person_add_alt_rounded),
                        title: Text(names[id] ?? 'A song no longer in it'),
                        subtitle: Text(by),
                      ),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
