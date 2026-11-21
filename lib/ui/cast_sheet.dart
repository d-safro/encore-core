import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../playback/cast.dart';
import '../playback/handler.dart';
import '../playback/upnp.dart';

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
    if (castInfo.value == null) _search = findSpeakers();
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
                    subtitle: Text(
                      'Your $deviceWord stays the remote: queue, media controls and buttons work as usual',
                    ),
                  ),
                  if (!info.connecting)
                    Row(
                      children: [
                        const Padding(padding: EdgeInsets.only(left: 16), child: Icon(Icons.volume_down_rounded)),
                        Expanded(
                          child: Semantics(
                            label: 'Speaker volume',
                            child: Slider(value: info.volume, onChanged: audioHandler.setCastVolume),
                          ),
                        ),
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
                          ListTile(
                            leading: const Icon(Icons.cast_rounded),
                            title: const Text('Nothing found'),
                            subtitle: Text(
                              'Chromecasts, Google / Nest speakers, Android TVs and UPnP / DLNA speakers, TVs and receivers show here when the $deviceWord is on '
                              'the same network${isDesktop ? ' (and the firewall lets the speaker in: see the README)' : ' Wi-Fi'}.',
                            ),
                          ),
                        for (final d in found)
                          ListTile(
                            leading: Icon(
                              d.model.toLowerCase().contains('tv') ? Icons.tv_rounded : Icons.speaker_rounded,
                            ),
                            title: Text(d.name),
                            subtitle: Text([if (d.model.isNotEmpty) d.model, d.isUpnp ? 'UPnP / DLNA' : 'Google Cast'].join(' · ')),
                            onTap: () => audioHandler.startCasting(d),
                          ),
                        TextButton.icon(
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Search again'),
                          onPressed: () => setState(() => _search = findSpeakers()),
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
