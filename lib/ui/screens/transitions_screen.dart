import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/models.dart';
import '../../playback/transitions.dart';

/// A playlist's menu > Edit transitions: for each song and the next, Smart (Automix), Fade, Cut, or as in
/// Settings. Used when the playlist plays in this order (and on your other devices).
class TransitionsScreen extends ConsumerStatefulWidget {
  const TransitionsScreen({super.key, required this.playlist});
  final Playlist playlist;
  @override
  ConsumerState<TransitionsScreen> createState() => _TransitionsScreenState();
}

class _TransitionsScreenState extends ConsumerState<TransitionsScreen> {
  @override
  Widget build(BuildContext context) {
    final p = widget.playlist;
    final songs = p.songs.where((s) => !s.isLookup).toList();
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit transitions')),
      body: songs.length < 2
          ? const Center(child: Text('A playlist needs two songs or more for this'))
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 32),
              itemCount: songs.length,
              itemBuilder: (_, i) {
                final s = songs[i];
                final row = ListTile(
                  dense: true,
                  title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                );
                if (i == songs.length - 1) return row;
                final next = songs[i + 1];
                final chosen = transitionFor(p.id, s.id, next.id);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    row,
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Row(
                        children: [
                          Icon(Icons.south_rounded, size: 18, color: cs.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SegmentedButton<TransitionKind?>(
                              segments: [
                                const ButtonSegment(value: null, label: Text('Settings')),
                                for (final k in TransitionKind.values)
                                  ButtonSegment(value: k, label: Text(transitionLabels[k]!)),
                              ],
                              selected: {chosen},
                              showSelectedIcon: false,
                              emptySelectionAllowed: false,
                              onSelectionChanged: (v) async {
                                await setTransition(p.id, s.id, next.id, v.first);
                                if (mounted) setState(() {});
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Smart: the next song comes in at the fade, beat on beat (Automix). Fade: the crossfade. Cut: straight on, no gap.',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}
