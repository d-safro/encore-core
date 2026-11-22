import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../data/devices.dart';
import '../data/models.dart' show formatDuration;
import '../playback/private_session.dart';
import 'actions.dart';
import 'cast_sheet.dart';
import 'widgets.dart';

/// Your other devices running Encore: what each is playing, and moving playback between them or controlling
/// one from here (like Spotify Connect). Cast speakers are one tap further.
Future<void> showDevicesSheet(BuildContext context) => showModalBottomSheet(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => const _DevicesSheet(),
);

IconData deviceIcon(String kind) => switch (kind) {
  'computer' => Icons.computer_rounded,
  'tablet' => Icons.tablet_android_rounded,
  _ => Icons.smartphone_rounded,
};

class _DevicesSheet extends ConsumerWidget {
  const _DevicesSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(devicesProvider);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final online = st.online;
    final privateUntil = ref.watch(privateSessionProvider);
    final privateOn = privateSessionOn(privateUntil, DateTime.now());
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('Your devices', style: t.titleLarge),
            ),
            ListTile(
              leading: Icon(deviceIcon(deviceKind()), color: cs.primary),
              title: Text(deviceName()),
              subtitle: const Text('This device'),
            ),
            SwitchListTile(
              secondary: Icon(Icons.lock_outline_rounded, color: privateOn ? Theme.of(context).colorScheme.primary : null),
              title: const Text('Private session'),
              subtitle: Text(privateSessionLabel(privateUntil)),
              value: privateOn,
              onChanged: (v) => ref.read(privateSessionProvider.notifier).set(v),
            ),
            if (st.supported == false)
              const ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('Your server can\'t connect your devices'),
                subtitle: Text('This needs Conductor or music-lookup. "Continue from another device" on Home '
                    'still picks up the queue saved on the server.'),
              )
            else if (online.isEmpty)
              ListTile(
                leading: const Icon(Icons.devices_other_rounded),
                title: const Text('No other device is open right now'),
                subtitle: Text(isDesktop
                    ? 'Open Encore on your phone (same server and account) and it shows up here.'
                    : 'Open Encore on your computer (same server and account) and it shows up here.'),
              ),
            for (final d in online) _DeviceCard(d),
            const Divider(height: 24),
            ListTile(
              leading: const Icon(Icons.cast_rounded),
              title: const Text('Cast to a speaker or TV'),
              subtitle: const Text('Chromecast / Google Cast on this network'),
              onTap: () {
                Navigator.pop(context);
                showCastSheet(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends ConsumerWidget {
  const _DeviceCard(this.d);
  final RemoteDevice d;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final s = d.state;
    final n = ref.read(devicesProvider.notifier);
    Future<void> act(Future<bool> Function() f, String failed) async {
      final ok = await f();
      if (!context.mounted) return;
      if (ok) {
        Navigator.pop(context);
      } else {
        toast(context, failed);
      }
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: Icon(deviceIcon(d.kind)),
              title: Text(d.name),
              subtitle: Text(!s.hasSong
                  ? 'Nothing playing'
                  : '${s.playing ? 'Playing' : 'Paused'}: ${s.title}${s.artist.isEmpty ? '' : ' · ${s.artist}'}'),
              trailing: s.hasSong ? Cover(s.coverArt, size: 44, radius: 8, artist: s.artist, album: s.album) : null,
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                if (s.hasSong)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: const Text('Play here'),
                    onPressed: () => act(() => n.playHere(d), "Couldn't take over what's playing there"),
                  ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.upload_rounded, size: 18),
                  label: Text('Play on ${d.name}'),
                  onPressed: () => act(() => n.playThere(d), 'Nothing is playing here to send'),
                ),
                if (s.hasSong)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.settings_remote_rounded, size: 18),
                    label: const Text('Remote'),
                    onPressed: () {
                      Navigator.pop(context);
                      showRemoteControl(context, d.id);
                    },
                  ),
              ],
            ),
            if (s.hasSong) const SizedBox(height: 4),
            if (s.hasSong)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Volume ${(s.volume * 100).round()} %',
                  style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A remote for another device: what it plays, and play / pause / skip / seek / volume sent to it.
Future<void> showRemoteControl(BuildContext context, String id) => showModalBottomSheet(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => _Remote(id),
);

class _Remote extends ConsumerStatefulWidget {
  const _Remote(this.id);
  final String id;
  @override
  ConsumerState<_Remote> createState() => _RemoteState();
}

class _RemoteState extends ConsumerState<_Remote> {
  Timer? _tick;
  double? _seek, _volume;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {})); // the position moves on
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(devicesProvider);
    final d = st.byId(widget.id);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final n = ref.read(devicesProvider.notifier);
    if (d == null || !d.online) {
      return const SafeArea(
        child: Padding(padding: EdgeInsets.all(24), child: Text('That device isn\'t open any more.')),
      );
    }
    final s = d.state;
    final dur = s.durationMs.toDouble();
    final pos = (_seek ?? s.positionAt(st.now).toDouble()).clamp(0.0, dur > 0 ? dur : 1.0);
    void send(String type, [Map<String, dynamic> args = const {}]) => n.send(d.id, type, args);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(deviceIcon(d.kind), size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Text('Playing on ${d.name}', style: t.labelLarge?.copyWith(color: cs.primary)),
              ],
            ),
            const SizedBox(height: 16),
            Cover(s.coverArt, size: 180, radius: 16, artist: s.artist, album: s.album),
            const SizedBox(height: 16),
            Text(s.title, style: t.titleLarge, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(s.artist, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
            Semantics(label: 'Position', child: Slider(
              value: pos,
              max: dur > 0 ? dur : 1,
              onChanged: dur > 0 ? (v) => setState(() => _seek = v) : null,
              onChangeEnd: (v) {
                send(DeviceCommand.seek, {'position': v.round()});
                setState(() => _seek = null);
              },
            )),
            Row(
              children: [
                Text(formatDuration(pos ~/ 1000), style: t.labelSmall),
                const Spacer(),
                Text(formatDuration(s.durationMs ~/ 1000), style: t.labelSmall),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 36,
                  tooltip: 'Previous',
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: () => send(DeviceCommand.previous),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  iconSize: 40,
                  tooltip: s.playing ? 'Pause' : 'Play',
                  icon: Icon(s.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  onPressed: () => send(s.playing ? DeviceCommand.pause : DeviceCommand.play),
                ),
                const SizedBox(width: 8),
                IconButton(
                  iconSize: 36,
                  tooltip: 'Next',
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: () => send(DeviceCommand.next),
                ),
              ],
            ),
            Row(
              children: [
                const Icon(Icons.volume_down_rounded),
                Expanded(
                  child: Semantics(label: 'Volume', child: Slider(
                    value: _volume ?? s.volume,
                    onChanged: (v) => setState(() => _volume = v),
                    onChangeEnd: (v) {
                      send(DeviceCommand.volume, {'volume': v});
                      Future.delayed(const Duration(seconds: 2), () {
                        if (mounted) setState(() => _volume = null);
                      });
                    },
                  )),
                ),
                const Icon(Icons.volume_up_rounded),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.download_rounded),
              label: const Text('Play here instead'),
              onPressed: () async {
                final ok = await n.playHere(d);
                if (context.mounted && ok) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}
