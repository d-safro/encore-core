import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/platform.dart';
import 'package:material_ui/material_ui.dart';

import '../core/settings.dart';
import '../data/library.dart';
import 'actions.dart';
import 'widgets.dart' show nSongs;

String _mb(int bytes) => bytes >= 1 << 30
    ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB'
    : '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';

/// Download quality like Spotify's (Low / Normal / High / Very high, plus Lossless), then an offer to make
/// songs already on the phone smaller.
Future<void> pickDownloadQuality(BuildContext context, WidgetRef ref) async {
  final s = ref.read(settingsProvider);
  final now = downloadLevelOf(s.downloadFormat, s.downloadBitrate);
  final picked = await showModalBottomSheet<(String, String, int, String)>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text('Download quality', style: Theme.of(ctx).textTheme.titleLarge),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Songs you download are made smaller on your server first, like Spotify does.'),
            ),
            for (final l in downloadLevels)
              ListTile(
                leading: Icon(l == now ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                title: Text(l.$1 + (l.$1 == 'High' ? ' (recommended)' : '')),
                subtitle: Text(l.$4),
                onTap: () => Navigator.pop(ctx, l),
              ),
          ],
        ),
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  ref.read(settingsProvider.notifier).update({'downloadFormat': picked.$2, 'downloadBitrate': picked.$3});
  if (picked.$2 != 'raw') await offerShrink(context, ref);
}

/// "Make your downloads smaller?" when songs on the phone are bigger than the download quality makes them.
Future<void> offerShrink(BuildContext context, WidgetRef ref) async {
  final dl = ref.read(downloadsProvider.notifier);
  final big = await dl.oversized();
  if (big.isEmpty || !context.mounted) return;
  final s = ref.read(settingsProvider);
  final level = downloadLevelOf(s.downloadFormat, s.downloadBitrate)?.$1 ?? '${s.downloadBitrate} kbps';
  final now = big.fold<int>(0, (n, e) => n + e.$3);
  final after = big.fold<int>(0, (n, e) => n + DownloadsNotifier.sizeAt(e.$1.first, s.downloadBitrate));
  final ok = await confirm(
    context,
    'Make your downloads smaller?',
    '${nSongs(big.length)} take ${_mb(now)}. At $level they\'d take about ${_mb(after)}, '
        'freeing ${_mb(now - after)}.\n\nEach song keeps playing from the $deviceWord until its smaller copy has '
        'arrived${s.downloadWifiOnly ? ' (on Wi-Fi)' : ''}.',
    ok: 'Make smaller',
  );
  if (!ok) return;
  await dl.shrink(big);
  if (context.mounted) toast(context, 'Making ${nSongs(big.length)} smaller in the background');
}

/// On the Downloads screen: how much space smaller copies would free, or how far shrinking has got.
class ShrinkCard extends ConsumerStatefulWidget {
  const ShrinkCard({super.key});
  @override
  ConsumerState<ShrinkCard> createState() => _ShrinkCardState();
}

class _ShrinkCardState extends ConsumerState<ShrinkCard> {
  Future<List<(List, String, int)>>? _big;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    ref.watch(downloadsProvider.select((d) => d.files)); // swapped for smaller copies: look again
    final dl = ref.read(downloadsProvider.notifier);
    _big = dl.oversized();
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<(int, int)?>(
      valueListenable: dl.shrinking,
      builder: (ctx, progress, _) {
        if (progress != null) {
          return Card(
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: ListTile(
              leading: const Icon(Icons.compress_rounded),
              title: Text('Making songs smaller: ${progress.$1} of ${progress.$2}'),
              subtitle: LinearProgressIndicator(value: progress.$2 == 0 ? null : progress.$1 / progress.$2),
            ),
          );
        }
        return FutureBuilder<List<(List, String, int)>>(
          future: _big,
          builder: (ctx, snap) {
            final big = snap.data ?? const [];
            if (big.isEmpty) return const SizedBox.shrink();
            final now = big.fold<int>(0, (n, e) => n + e.$3);
            final level = downloadLevelOf(s.downloadFormat, s.downloadBitrate)?.$1 ?? 'your download quality';
            return Card(
              color: cs.primaryContainer.withValues(alpha: 0.35),
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: ListTile(
                leading: const Icon(Icons.compress_rounded),
                title: Text('${nSongs(big.length)} use ${_mb(now)}'),
                subtitle: Text('They were downloaded bigger than $level makes them'),
                trailing: FilledButton.tonal(
                  onPressed: () => offerShrink(context, ref),
                  child: const Text('Shrink'),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
