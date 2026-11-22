import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../data/models.dart';
import 'screens/player.dart' show artSchemeProvider;
import 'share_picture.dart';
import 'widgets.dart';

/// Lyric cards: hold a line in the lyrics to make a picture of it (and up to three more lines) with the song's
/// cover and colours, to share (phone) or save (desktop).
const maxCardLines = 4;

/// The lines a card shows: from [first], at most [maxCardLines], blank lines left out.
List<String> cardLines(List<LyricLine> lines, int first, int count) => [
  for (final l in lines.skip(first).take(count.clamp(1, maxCardLines))) if (l.text.trim().isNotEmpty) l.text.trim(),
];

Future<void> showLyricCard(BuildContext context, Song song, List<LyricLine> lines, int first) => showModalBottomSheet(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => _LyricCardSheet(song, lines, first),
);

class _LyricCardSheet extends StatefulWidget {
  const _LyricCardSheet(this.song, this.lines, this.first);
  final Song song;
  final List<LyricLine> lines;
  final int first;
  @override
  State<_LyricCardSheet> createState() => _LyricCardSheetState();
}

class _LyricCardSheetState extends State<_LyricCardSheet> {
  final _key = GlobalKey();
  int _count = 2;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final shown = cardLines(widget.lines, widget.first, _count);
    final left = widget.lines.length - widget.first;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: AspectRatio(
                aspectRatio: 4 / 5,
                child: RepaintBoundary(key: _key, child: LyricCard(song: widget.song, lines: shown)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'One line less',
                  icon: const Icon(Icons.remove_rounded),
                  onPressed: _count > 1 ? () => setState(() => _count--) : null,
                ),
                Text('$_count line${_count == 1 ? '' : 's'}'),
                IconButton(
                  tooltip: 'One line more',
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _count < maxCardLines && _count < left ? () => setState(() => _count++) : null,
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _busy || shown.isEmpty
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          await sharePicture(context, _key, 'encore-${widget.song.artist}-${widget.song.title}-lyrics',
                              text: '${widget.song.title} · ${widget.song.artist}');
                          if (mounted) setState(() => _busy = false);
                        },
                  icon: Icon(isDesktop ? Icons.download_rounded : Icons.share_rounded),
                  label: Text(isDesktop ? 'Save picture' : 'Share'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The picture: the lines big, on the cover's colours, with the song under them.
class LyricCard extends ConsumerWidget {
  const LyricCard({super.key, required this.song, required this.lines});
  final Song song;
  final List<String> lines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = ref.watch(artSchemeProvider(song.coverArt)).value ?? Theme.of(context).colorScheme;
    final bg = Color.lerp(scheme.primary, Colors.black, 0.35)!;
    return LayoutBuilder(
      builder: (context, box) {
        final u = box.maxWidth / 320;
        return ClipRRect(
          borderRadius: BorderRadius.circular(20 * u),
          child: ColoredBox(
            color: bg,
            child: Padding(
              padding: EdgeInsets.all(22 * u),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Cover(song.coverArt, size: 40 * u, radius: 6 * u, icon: Icons.music_note_rounded),
                      SizedBox(width: 10 * u),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14 * u)),
                            Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Colors.white70, fontSize: 12 * u)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // the lines as big as they fit (long ones get smaller rather than run off the card)
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: box.maxWidth - 44 * u,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final l in lines)
                                Padding(
                                  padding: EdgeInsets.only(bottom: 6 * u),
                                  child: Text(l, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800,
                                      fontSize: (lines.length > 2 ? 20 : 24) * u, height: 1.2)),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Text('ENCORE', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w800,
                      fontSize: 10 * u, letterSpacing: 3 * u)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
