import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/jam.dart';
import '../../data/library.dart';
import '../actions.dart';

/// Start / show / end a Jam: friends scan the code or open the link to add songs to the queue.
Future<void> showJamSheet(BuildContext context) => showModalBottomSheet(
  useRootNavigator: true,
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const _JamSheet(),
);

class _JamSheet extends ConsumerWidget {
  const _JamSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jam = ref.watch(jamProvider);
    final online = ref.watch(repoProvider).online;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.groups_rounded, color: cs.primary),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ensemble', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    Text('Listen together', style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
                const Spacer(),
                if (jam.active)
                  Chip(
                    avatar: const Icon(Icons.person_rounded, size: 16),
                    label: Text(jam.guests == 1 ? '1 guest' : '${jam.guests} guests'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (!jam.active) ...[
              Text(
                'Friends open a link (or scan a code), search your library and add songs to what\'s playing. '
                'They can also reorder, remove and skip. Songs you don\'t have download first.',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              if (jam.error != null) ...[
                const SizedBox(height: 12),
                Text(jam.error!, style: t.bodyMedium?.copyWith(color: cs.error)),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: jam.busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow_rounded),
                label: const Text('Start an Ensemble'),
                onPressed: !online || jam.busy ? null : () => ref.read(jamProvider.notifier).start(),
              ),
              if (!online)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Needs your server', style: t.bodySmall, textAlign: TextAlign.center),
                ),
            ] else ...[
              Text(
                'Anyone with this link can add songs, reorder, remove and skip until you end the Ensemble.',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                  child: SizedBox(width: 220, height: 220, child: QrView(jam.url!)),
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(
                jam.url!,
                textAlign: TextAlign.center,
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.share_rounded),
                      label: const Text('Share link'),
                      onPressed: () => SharePlus.instance.share(
                        ShareParams(text: 'Join my Ensemble and add songs to what we listen to: ${jam.url}', subject: 'Ensemble'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Copy link',
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: jam.url!));
                      toast(context, 'Link copied');
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.stop_rounded),
                label: const Text('End the Ensemble'),
                onPressed: () async {
                  if (await confirm(context, 'End the Ensemble?', 'The link stops working for everyone.', ok: 'End')) {
                    await ref.read(jamProvider.notifier).end();
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A QR code for [data], drawn directly (black on the white card around it).
class QrView extends StatelessWidget {
  const QrView(this.data, {super.key});
  final String data;
  @override
  Widget build(BuildContext context) {
    final img = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));
    return CustomPaint(painter: _QrPainter(img), size: Size.infinite);
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.img);
  final QrImage img;
  @override
  void paint(Canvas canvas, Size size) {
    final n = img.moduleCount;
    final cell = size.shortestSide / n;
    final paint = Paint()
      ..color = const Color(0xFF000000)
      ..isAntiAlias = false;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (img.isDark(r, c)) canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell + 0.5, cell + 0.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.img != img;
}
