import 'package:material_ui/material_ui.dart';

import '../playback/cast.dart';
import '../playback/handler.dart';

/// Play on a Chromecast / Google Cast speaker or TV on this Wi-Fi, or stop.
Future<void> showCastSheet(BuildContext context) => showModalBottomSheet(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  builder: (_) => const _CastSheet(),
);

class _CastSheet extends StatefulWidget {
  const _CastSheet();
  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> {
  Future<List<CastDevice>>? _search;

  @override
  void initState() {
    super.initState();
    if (castInfo.value == null) _search = findCastDevices();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
        child: ValueListenableBuilder<CastInfo?>(
          valueListenable: castInfo,
          builder: (ctx, info, _) {
            if (info != null) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: Icon(info.connecting ? Icons.cast_rounded : Icons.cast_connected_rounded),
                    title: Text(info.connecting ? 'Connecting to ${info.name}…' : 'Playing on ${info.name}'),
                    subtitle: const Text('Your phone stays the remote: queue, lock screen and buttons work as usual'),
                  ),
                  if (!info.connecting)
                    Row(
                      children: [
                        const Padding(padding: EdgeInsets.only(left: 16), child: Icon(Icons.volume_down_rounded)),
                        Expanded(child: Slider(value: info.volume, onChanged: audioHandler.setCastVolume)),
                        const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Icons.volume_up_rounded)),
                      ],
                    ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: FilledButton.tonal(
                      onPressed: () async {
                        await audioHandler.stopCasting();
                        if (context.mounted) Navigator.pop(context);
                      },
                      child: const Text('Stop casting'),
                    ),
                  ),
                ],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('Play on', style: t.titleLarge),
                ),
                FutureBuilder<List<CastDevice>>(
                  future: _search,
                  builder: (ctx, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const ListTile(
                        leading: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                        title: Text('Looking for speakers and TVs on this Wi-Fi…'),
                      );
                    }
                    final found = snap.data ?? const <CastDevice>[];
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (found.isEmpty)
                          const ListTile(
                            leading: Icon(Icons.cast_rounded),
                            title: Text('Nothing found'),
                            subtitle: Text(
                              'Chromecasts, Google / Nest speakers and Android TVs show here when the phone is on '
                              'the same Wi-Fi.',
                            ),
                          ),
                        for (final d in found)
                          ListTile(
                            leading: Icon(d.model.toLowerCase().contains('tv') ? Icons.tv_rounded : Icons.speaker_rounded),
                            title: Text(d.name),
                            subtitle: d.model.isEmpty ? null : Text(d.model),
                            onTap: () => audioHandler.startCasting(d),
                          ),
                        TextButton.icon(
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Search again'),
                          onPressed: () => setState(() => _search = findCastDevices()),
                        ),
                      ],
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
