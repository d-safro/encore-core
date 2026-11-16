import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:home_widget/home_widget.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/settings.dart';
import '../../data/account.dart';
import '../../data/cover_cache.dart';
import '../../data/episode_alerts.dart';
import '../../data/updates.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../data/online_lyrics.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../update.dart';
import '../download_quality.dart';
import '../widgets.dart';
import 'login.dart';

const _formats = {'raw': 'Original', 'opus': 'Opus', 'mp3': 'MP3', 'aac': 'AAC'};
const _bitrates = [64, 96, 128, 160, 192, 256, 320];
const _accents = [0xFF6750A4, 0xFF006A6A, 0xFF8B5000, 0xFFB3261E, 0xFF386A20, 0xFF0061A4, 0xFF984061, 0xFF5D5F00];

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final creds = ref.watch(accountProvider).value;
    final sync = ref.watch(syncProvider);
    void set(String k, Object v) => n.update({k: v});

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const SectionTitle('Server'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(creds?.base ?? ''),
            subtitle: Text('Signed in as ${creds?.username ?? ''}'),
            trailing: TextButton(
              onPressed: () async {
                if (await confirm(context, 'Sign out?', 'Downloads stay on the phone.', ok: 'Sign out')) {
                  await ref.read(accountProvider.notifier).signOut(beforeSwitch: audioHandler.leaveServer);
                  await audioHandler.enterServer();
                }
              },
              child: const Text('Sign out'),
            ),
          ),
          const _OtherServers(),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_off_outlined),
            title: const Text('Offline mode'),
            subtitle: const Text('Only downloaded music; nothing goes over the network'),
            value: s.offlineMode,
            onChanged: (v) => set('offlineMode', v),
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: const Text('Save library on the phone'),
            subtitle: Text(
              sync.running
                  ? sync.message
                  : [
                      if (sync.message.isNotEmpty) sync.message,
                      if (sync.last != null) 'Last: ${MaterialLocalizations.of(context).formatShortDate(sync.last!)}',
                      'For browsing and searching offline',
                    ].join(' · '),
            ),
            trailing: sync.running
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : FilledButton.tonal(
                    onPressed: () => ref.read(syncProvider.notifier).sync(),
                    child: const Text('Sync now'),
                  ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_download_outlined),
            title: const Text('Show music you don\'t have'),
            subtitle: const Text('Search and album pages include songs your server can download (music-lookup)'),
            value: s.showLookup,
            onChanged: (v) => set('showLookup', v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.image_search_rounded),
            title: const Text('Find missing covers online'),
            subtitle: const Text('From iTunes / Deezer when your server has no picture (sends artist and album)'),
            value: s.onlineCovers,
            onChanged: (v) => set('onlineCovers', v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.lyrics_outlined),
            title: const Text('Find lyrics online'),
            subtitle: const Text('When your server has none (sends title, artist, album)'),
            value: s.onlineLyrics,
            onChanged: (v) => set('onlineLyrics', v),
          ),
          if (s.onlineLyrics)
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Lyrics sources'),
              subtitle: Text(
                s.lyricsSources.isEmpty ? 'None' : s.lyricsSources.map((k) => lyricsSourceNames[k] ?? k).join(' → '),
              ),
              onTap: () => showDialog(context: context, builder: (_) => const _LyricsSourcesDialog()),
            ),
          SwitchListTile(
            secondary: const Icon(Icons.podcasts_rounded),
            title: const Text('New podcast episodes'),
            subtitle: const Text('A notification when a show you follow has a new episode'),
            value: prefs.getBool('podcastAlerts') ?? true,
            onChanged: (v) async {
              await prefs.setBool('podcastAlerts', v);
              if (v) await askNotificationPermission(prefs);
              ref.invalidate(settingsProvider); // redraw
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.history),
            title: const Text('Scrobble plays'),
            subtitle: const Text('Play counts, Last.fm / ListenBrainz through the server'),
            value: s.scrobble,
            onChanged: (v) => set('scrobble', v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.devices),
            title: const Text('Keep the queue on the server'),
            subtitle: const Text('Continue where you left off on another device or in Feishin'),
            value: s.syncPlayQueue,
            onChanged: (v) => set('syncPlayQueue', v),
          ),

          const SectionTitle('Look'),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Colours'),
            subtitle: SegmentedButton<ThemeSource>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeSource.wallpaper, label: Text('Wallpaper')),
                ButtonSegment(value: ThemeSource.albumArt, label: Text('Album art')),
                ButtonSegment(value: ThemeSource.fixed, label: Text('Pick')),
              ],
              selected: {s.themeSource},
              onSelectionChanged: (v) => set('themeSource', v.first.name),
            ),
          ),
          if (s.themeSource == ThemeSource.fixed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 72, vertical: 4),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in _accents)
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => set('accentColor', c),
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: Color(c),
                        child: s.accentColor == c ? const Icon(Icons.check, color: Colors.white) : null,
                      ),
                    ),
                ],
              ),
            ),
          SwitchListTile(
            secondary: const Icon(Icons.contrast),
            title: const Text('Pure black'),
            subtitle: const Text('Black backgrounds (saves battery on OLED screens)'),
            value: s.pureBlack,
            onChanged: (v) => set('pureBlack', v),
          ),
          ListTile(
            leading: const Icon(Icons.widgets_outlined),
            title: const Text('Add the widget to your home screen'),
            subtitle: const Text('What\'s playing, with play, pause and skip'),
            onTap: () => HomeWidget.requestPinWidget(qualifiedAndroidName: 'dev.safro.encore.EncoreWidget'),
          ),
          ListTile(
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: const Text('Home screen'),
            subtitle: Text(s.homeSections.map(_sectionName).join(', ')),
            onTap: () => _editHome(context, ref, s),
          ),

          const SectionTitle('Playback'),
          ListTile(
            leading: const Icon(Icons.equalizer),
            title: const Text('Equalizer'),
            subtitle: Text(s.eqEnabled ? 'On' : 'Off'),
            onTap: () => context.push('/equalizer'),
          ),
          ListTile(
            leading: const Icon(Icons.volume_up_outlined),
            title: const Text('ReplayGain'),
            subtitle: Text(
              '${switch (s.replayGain) {
                ReplayGainMode.off => 'Off',
                ReplayGainMode.track => 'Track',
                ReplayGainMode.album => 'Album',
                ReplayGainMode.auto => 'Automatic (album when playing an album)',
              }}${s.replayGain != ReplayGainMode.off ? ' · pre-amp ${s.replayGainPreamp.toStringAsFixed(0)} dB' : ''}',
            ),
            onTap: () => _replayGain(context, ref, s),
          ),
          ListTile(
            leading: const Icon(Icons.compare_arrows_rounded),
            title: const Text('Crossfade'),
            subtitle: Text(s.crossfade == 0 ? 'Off: songs follow each other with no gap' : 'The last ${s.crossfade} s of a song blend into the next'),
          ),
          Slider(
            value: s.crossfade.toDouble(),
            max: 12,
            divisions: 12,
            label: s.crossfade == 0 ? 'Off' : '${s.crossfade} s',
            onChanged: (v) => set('crossfade', v.round()),
          ),
          if (s.crossfade > 0)
            SwitchListTile(
              secondary: const SizedBox(width: 24),
              title: const Text('Crossfade inside albums'),
              subtitle: const Text('Off keeps an album played in order seamless, like a live record'),
              value: s.crossfadeAlbums,
              onChanged: (v) => set('crossfadeAlbums', v),
            ),
          SwitchListTile(
            secondary: const Icon(Icons.fast_forward_outlined),
            title: const Text('Skip silence'),
            value: s.skipSilence,
            onChanged: (v) => set('skipSilence', v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.all_inclusive),
            title: const Text('Endless playback'),
            subtitle: const Text('When the queue ends, keep going with songs that sound similar'),
            value: s.endlessRadio,
            onChanged: (v) => set('endlessRadio', v),
          ),

          const SectionTitle('Streaming quality'),
          _QualityTile(
            icon: Icons.wifi,
            title: 'On Wi-Fi',
            format: s.wifiFormat,
            bitrate: s.wifiBitrate,
            onChanged: (f, b) => n.update({'wifiFormat': f, 'wifiBitrate': b}),
          ),
          _QualityTile(
            icon: Icons.signal_cellular_alt,
            title: 'On mobile data',
            format: s.mobileFormat,
            bitrate: s.mobileBitrate,
            onChanged: (f, b) => n.update({'mobileFormat': f, 'mobileBitrate': b}),
          ),

          const SectionTitle('Downloads'),
          ListTile(
            leading: const Icon(Icons.offline_pin_outlined),
            title: const Text('Downloaded music'),
            subtitle: Text(nSongs(ref.watch(downloadsProvider).files.length)),
            onTap: () => context.push('/downloads'),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Download quality'),
            subtitle: Text(
              downloadLevelOf(s.downloadFormat, s.downloadBitrate)?.$1 ??
                  '${s.downloadFormat.toUpperCase()} · ${s.downloadBitrate} kbps',
            ),
            onTap: () => pickDownloadQuality(context, ref),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi_lock),
            title: const Text('Download only on Wi-Fi'),
            value: s.downloadWifiOnly,
            onChanged: (v) => set('downloadWifiOnly', v),
          ),

          const SectionTitle('About'),
          const ListTile(
            leading: EncoreLogo(size: 28),
            title: Text('Encore $appVersion'),
            subtitle: Text('A music player for Navidrome and other Subsonic servers'),
          ),
          const _AppIconPicker(),
          const _CoverCacheTile(),
          SwitchListTile(
            secondary: const Icon(Icons.system_update_rounded),
            title: const Text('Check for updates'),
            subtitle: const Text('Asks GitHub about twice a day and offers new versions'),
            value: autoUpdateChecks(prefs),
            onChanged: (v) async {
              await prefs.setBool('updateChecks', v);
              ref.invalidate(settingsProvider); // redraw
            },
          ),
          ListTile(
            leading: const Icon(Icons.refresh_rounded),
            title: const Text('Check now'),
            onTap: () => checkForUpdatesNow(context),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  static String _sectionName(String k) =>
      const {
        'recent': 'Recently played',
        'newest': 'Recently added',
        'frequent': 'Most played',
        'starred': 'Favourite albums',
        'random': 'Discover',
        'highest': 'Top rated',
        'playlists': 'Playlists',
      }[k] ??
      k;

  Future<void> _editHome(BuildContext context, WidgetRef ref, Settings s) async {
    final all = ['recent', 'newest', 'frequent', 'starred', 'random', 'highest', 'playlists'];
    var chosen = [...s.homeSections.where(all.contains)];
    await showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Home screen sections'), subtitle: Text('Drag to reorder')),
              Flexible(
                child: ReorderableListView(
                  shrinkWrap: true,
                  onReorder: (a, b) => set(() {
                    final order = [...chosen, ...all.where((x) => !chosen.contains(x))];
                    if (b > a) b--;
                    order.insert(b, order.removeAt(a));
                    chosen = order.where(chosen.contains).toList();
                  }),
                  children: [
                    for (final k in [...chosen, ...all.where((x) => !chosen.contains(x))])
                      CheckboxListTile(
                        key: ValueKey(k),
                        value: chosen.contains(k),
                        title: Text(_sectionName(k)),
                        secondary: const Icon(Icons.drag_handle),
                        onChanged: (v) => set(() => v! ? chosen.add(k) : chosen.remove(k)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    ref.read(settingsProvider.notifier).update({'homeSections': chosen});
  }

  Future<void> _replayGain(BuildContext context, WidgetRef ref, Settings s) async {
    var mode = s.replayGain;
    var pre = s.replayGainPreamp;
    await showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ReplayGain', style: Theme.of(ctx).textTheme.titleMedium),
                const Text('Evens out loudness between songs using the volume tags in your files.'),
                const SizedBox(height: 12),
                SegmentedButton<ReplayGainMode>(
                  segments: const [
                    ButtonSegment(value: ReplayGainMode.off, label: Text('Off')),
                    ButtonSegment(value: ReplayGainMode.track, label: Text('Track')),
                    ButtonSegment(value: ReplayGainMode.album, label: Text('Album')),
                    ButtonSegment(value: ReplayGainMode.auto, label: Text('Auto')),
                  ],
                  selected: {mode},
                  onSelectionChanged: (v) => set(() => mode = v.first),
                ),
                const SizedBox(height: 12),
                Text('Pre-amp: ${pre.toStringAsFixed(0)} dB'),
                Slider(value: pre, min: -10, max: 10, divisions: 20, onChanged: (v) => set(() => pre = v)),
              ],
            ),
          ),
        ),
      ),
    );
    ref.read(settingsProvider.notifier).update({'replayGain': mode.name, 'replayGainPreamp': pre});
  }
}

class _QualityTile extends StatelessWidget {
  const _QualityTile({
    required this.icon,
    required this.title,
    required this.format,
    required this.bitrate,
    required this.onChanged,
  });
  final IconData icon;
  final String title, format;
  final int bitrate;
  final void Function(String format, int bitrate) onChanged;

  @override
  Widget build(BuildContext context) {
    final label = format == 'raw' ? 'Original files (FLAC stays FLAC)' : '${_formats[format]} · $bitrate kbps';
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(label),
      onTap: () async {
        var f = format;
        var b = bitrate == 0 ? 192 : bitrate;
        await showModalBottomSheet(
          useRootNavigator: true,
          context: context,
          showDragHandle: true,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, set) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final e in _formats.entries)
                          ChoiceChip(
                            label: Text(e.value),
                            selected: f == e.key,
                            onSelected: (_) => set(() => f = e.key),
                          ),
                      ],
                    ),
                    if (f != 'raw') ...[
                      const SizedBox(height: 16),
                      const Text('Bitrate (the server converts on the fly)'),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final r in _bitrates)
                            ChoiceChip(label: Text('$r'), selected: b == r, onSelected: (_) => set(() => b = r)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
        onChanged(f, f == 'raw' ? 0 : b);
      },
    );
  }
}

/// Pictures kept on the phone (covers, artist photos), with a way to free the space.
/// The launcher icon: Encore's, one drawn like line icon packs (Arcticons), or the original.
class _AppIconPicker extends StatefulWidget {
  const _AppIconPicker();
  @override
  State<_AppIconPicker> createState() => _AppIconPickerState();
}

class _AppIconPickerState extends State<_AppIconPicker> {
  static const _system = MethodChannel('encore/system');
  static const _choices = [
    ('IconScript', 'assets/icons/script.png', 'Encore'),
    ('IconLine', 'assets/icons/line.png', 'Line (icon packs)'),
    ('IconOriginal', 'assets/icons/original.png', 'Original'),
  ];
  String? _current;

  @override
  void initState() {
    super.initState();
    _system.invokeMethod<String>('icon').then((v) => mounted ? setState(() => _current = v) : null, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ListTile(
          leading: Icon(Icons.apps_rounded),
          title: Text('App icon'),
          subtitle: Text('Changes when you leave Encore; your home screen may take a moment to show it'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              for (final (name, asset, label) in _choices)
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () async {
                      setState(() => _current = name);
                      try {
                        await _system.invokeMethod('setIcon', {'name': name});
                      } catch (e) {
                        if (context.mounted) toast(context, "Couldn't change the icon: $e");
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: _current == name ? cs.primary : Colors.transparent, width: 2.5),
                            ),
                            child: ClipOval(child: Image.asset(asset, width: 64, height: 64)),
                          ),
                          const SizedBox(height: 6),
                          Text(label, style: t.labelMedium, textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Other saved servers (tap to switch), and adding one.
class _OtherServers extends ConsumerWidget {
  const _OtherServers();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cur = ref.watch(accountProvider).value;
    return FutureBuilder<List<SavedAccount>>(
      future: savedAccounts(),
      builder: (ctx, snap) {
        final others = (snap.data ?? const <SavedAccount>[])
            .where((a) => cur == null || !(a.server == cur.base && a.user == cur.username))
            .toList();
        return Column(
          children: [
            for (final a in others)
              ListTile(
                leading: const Icon(Icons.swap_horiz_rounded),
                title: Text(a.server),
                subtitle: Text('${a.user} · tap to switch'),
                onTap: () async {
                  toast(context, 'Switching to ${a.server}…');
                  try {
                    await ref.read(accountProvider.notifier).switchTo(a, beforeSwitch: audioHandler.leaveServer);
                    await audioHandler.enterServer();
                  } catch (e) {
                    if (context.mounted) toast(context, "Couldn't switch: $e");
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Add another server'),
              subtitle: const Text('Each keeps its own downloads, queue and pins'),
              onTap: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(builder: (_) => const LoginScreen(adding: true)),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CoverCacheTile extends StatefulWidget {
  const _CoverCacheTile();
  @override
  State<_CoverCacheTile> createState() => _CoverCacheTileState();
}

class _CoverCacheTileState extends State<_CoverCacheTile> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    var n = 0;
    try {
      final tmp = (await getTemporaryDirectory()).path;
      for (final name in ['encoreCovers', 'libCachedImageData']) {
        final dir = Directory('$tmp/$name');
        if (!await dir.exists()) continue;
        await for (final f in dir.list(recursive: true, followLinks: false)) {
          if (f is File) n += await f.length();
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _bytes = n);
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.image_outlined),
    title: const Text('Saved pictures'),
    subtitle: Text(
      _bytes == null ? 'Covers and artist photos kept on the phone' : '${(_bytes! / 1048576).toStringAsFixed(0)} MB of covers and artist photos',
    ),
    trailing: TextButton(
      onPressed: () async {
        await coverCache.emptyCache();
        await DefaultCacheManager().emptyCache();
        forgetCovers();
        PaintingBinding.instance.imageCache.clear();
        await _measure();
        if (context.mounted) toast(context, 'Cleared. Covers are fetched again as you browse.');
      },
      child: const Text('Clear'),
    ),
  );
}

class EqualizerScreen extends ConsumerStatefulWidget {
  const EqualizerScreen({super.key});
  @override
  ConsumerState<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends ConsumerState<EqualizerScreen> {
  void _safeSetState(VoidCallback f) {
    if (mounted) setState(f);
  }

  AndroidEqualizerParameters? _params;
  String? _error;

  static const _presets = {
    'Flat': [0.0, 0.0, 0.0, 0.0, 0.0],
    'Bass boost': [6.0, 4.0, 0.0, 0.0, 0.0],
    'Treble boost': [0.0, 0.0, 0.0, 3.0, 6.0],
    'Vocal': [-2.0, 0.0, 3.0, 2.0, 0.0],
    'Rock': [4.0, 2.0, -1.0, 2.0, 4.0],
    'Classical': [3.0, 1.0, 0.0, 1.0, 3.0],
  };

  @override
  void initState() {
    super.initState();
    audioHandler.equalizer.parameters
        .timeout(const Duration(seconds: 4))
        .then((p) => _safeSetState(() => _params = p))
        .catchError((Object e) {
          _safeSetState(() => _error = 'Start playing a song first, then open the equalizer.');
        });
  }

  void _save() {
    ref.read(settingsProvider.notifier).update({'eqGains': _params!.bands.map((b) => b.gain).toList()});
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final p = _params;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Equalizer'),
        actions: [
          Switch(value: s.eqEnabled, onChanged: (v) => ref.read(settingsProvider.notifier).update({'eqEnabled': v})),
          const SizedBox(width: 12),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
            )
          : p == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      for (final e in _presets.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                            label: Text(e.key),
                            onPressed: () async {
                              for (var i = 0; i < p.bands.length; i++) {
                                final g = i < e.value.length ? e.value[i] : 0.0;
                                await p.bands[i].setGain(g.clamp(p.minDecibels, p.maxDecibels));
                              }
                              _save();
                              _safeSetState(() {});
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final b in p.bands)
                        StreamBuilder<double>(
                          stream: b.gainStream,
                          builder: (ctx, snap) => Column(
                            children: [
                              Text(
                                '${(snap.data ?? b.gain).toStringAsFixed(1)} dB',
                                style: Theme.of(ctx).textTheme.labelSmall,
                              ),
                              Expanded(
                                child: RotatedBox(
                                  quarterTurns: -1,
                                  child: Slider(
                                    value: snap.data ?? b.gain,
                                    min: p.minDecibels,
                                    max: p.maxDecibels,
                                    onChanged: s.eqEnabled ? b.setGain : null,
                                    onChangeEnd: (_) => _save(),
                                  ),
                                ),
                              ),
                              Text(
                                b.centerFrequency >= 1000
                                    ? '${(b.centerFrequency / 1000).toStringAsFixed(1)}k'
                                    : '${b.centerFrequency.round()}',
                              ),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});
  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  void _safeSetState(VoidCallback f) {
    if (mounted) setState(f);
  }

  late Future<List<(Song, String, int)>> _future = ref.read(dbProvider).downloads();
  late final Future<(int, int)> _library = _librarySize();

  Future<(int, int)> _librarySize() async {
    final all = await ref.read(dbProvider).allSongs();
    return (all.length, all.fold<int>(0, (n, x) => n + (x.size ?? 0)));
  }

  String _gb(int bytes) =>
      bytes >= 1073741824 ? '${(bytes / 1073741824).toStringAsFixed(1)} GB' : '${(bytes / 1048576).round()} MB';

  Future<void> _toggle(String key, bool on, Future<List<Song>> Function() songs, String what) async {
    final n = ref.read(downloadsProvider.notifier);
    final list = (await songs()).where((x) => !x.isLookup).toList();
    if (on) {
      await n.pin(key, list);
      if (mounted) toast(context, 'Downloading $what');
    } else if (mounted &&
        await confirm(context, 'Remove $what from the phone?', 'Everything stays on your server.', ok: 'Remove')) {
      await n.unpin(key, list);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(downloadsProvider, (a, b) {
      if (a?.files.length != b.files.length) _safeSetState(() => _future = ref.read(dbProvider).downloads());
    });
    final dl = ref.watch(downloadsProvider);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: FutureBuilder(
        future: _future,
        builder: (ctx, snap) {
          final list = snap.data ?? const <(Song, String, int)>[];
          final songs = list.map((e) => e.$1).toList();
          final bytes = list.fold<int>(0, (n, e) => n + e.$3);
          final collections = dl.pins.where((k) => k.startsWith('album:') || k.startsWith('playlist:')).toList();
          return LazyListView(
            count: songs.length,
            itemBuilder: (_, i) => SongTile(songs[i], list: songs, index: i),
            footer: const [SizedBox(height: 24)],
            header: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${list.length} songs on this phone', style: t.headlineSmall),
                    Text(
                      '${_gb(bytes)} used${dl.progress.isNotEmpty ? ' · ${dl.progress.length} downloading' : ''}'
                      '${ref.watch(settingsProvider).downloadWifiOnly ? ' · Wi-Fi only' : ''}',
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    if (dl.progress.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: LinearProgressIndicator(
                          value: dl.progress.values.fold<double>(0, (a, b) => a + b) / dl.progress.length,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                  ],
                ),
              ),
              const ShrinkCard(),
              FutureBuilder<(int, int)>(
                future: _library,
                builder: (ctx, lib) => SwitchListTile(
                  secondary: const Icon(Icons.library_music_rounded),
                  title: const Text('Your whole library'),
                  subtitle: Text(
                    lib.hasData
                        ? '${lib.data!.$1} songs, about ${_gb(lib.data!.$2)}. New songs download too.'
                        : 'Every song, kept up to date',
                  ),
                  value: dl.pins.contains('library'),
                  onChanged: (v) => _toggle('library', v, () => ref.read(dbProvider).allSongs(), 'your whole library'),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.favorite_rounded),
                title: const Text('Liked songs'),
                subtitle: const Text('Songs you heart are downloaded automatically'),
                value: dl.pins.contains('starred'),
                onChanged: (v) => _toggle(
                  'starred',
                  v,
                  () async => (await ref.read(repoProvider).starred()).songs,
                  'your liked songs',
                ),
              ),
              if (collections.isNotEmpty) ...[
                const SectionTitle('Kept downloaded'),
                for (final k in collections) _PinnedRow(pinKey: k),
              ],
              if (songs.isNotEmpty) ...[
                SectionTitle(
                  'Songs',
                  trailing: TextButton(
                    onPressed: () async {
                      if (await confirm(
                        context,
                        'Remove all downloads?',
                        'Frees the space on the phone. Your server keeps everything.',
                        ok: 'Remove all',
                      )) {
                        for (final k in [...dl.pins]) {
                          ref.read(downloadsProvider.notifier).unpin(k, const []);
                        }
                        ref.read(downloadsProvider.notifier).remove(songs.map((e) => e.id));
                      }
                    },
                    child: const Text('Remove all'),
                  ),
                ),
                PlayButtons(
                  source: 'downloads',
                  onPlay: () => audioHandler.playSongs(songs, source: 'downloads'),
                  onShuffle: () => audioHandler.playSongs(songs, shuffle: true, source: 'downloads'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// A playlist or album that's kept downloaded, with its name and a way to stop.
class _PinnedRow extends ConsumerWidget {
  const _PinnedRow({required this.pinKey});
  final String pinKey;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAlbum = pinKey.startsWith('album:');
    final id = pinKey.substring(isAlbum ? 6 : 9);
    final repo = ref.watch(repoProvider);
    return FutureBuilder<(String, String, List<Song>)>(
      future: isAlbum
          ? repo.album(id).then((a) => (a.name, a.coverArt, a.songs))
          : repo.playlist(id).then((p) => (p.name, p.coverArt, p.songs)),
      builder: (ctx, snap) {
        final (name, cover, songs) = snap.data ?? ('…', '', const <Song>[]);
        final files = ref.watch(downloadsProvider).files;
        final have = songs.where((x) => files.containsKey(x.id)).length;
        return ListTile(
          leading: Cover(cover, size: 48, icon: isAlbum ? Icons.album_outlined : Icons.queue_music_rounded),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            songs.isEmpty
                ? (isAlbum ? 'Album' : 'Playlist')
                : '$have of ${songs.where((x) => !x.isLookup).length} songs downloaded',
          ),
          onTap: () => context.push(isAlbum ? '/album/$id' : '/playlist/$id'),
          trailing: IconButton(
            tooltip: 'Stop keeping it downloaded',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => ref.read(downloadsProvider.notifier).unpin(pinKey, songs),
          ),
        );
      },
    );
  }
}

/// Which online lyrics sources to use, and in what order (drag to reorder).
class _LyricsSourcesDialog extends ConsumerStatefulWidget {
  const _LyricsSourcesDialog();
  @override
  ConsumerState<_LyricsSourcesDialog> createState() => _LyricsSourcesDialogState();
}

class _LyricsSourcesDialogState extends ConsumerState<_LyricsSourcesDialog> {
  late final List<String> _order;
  late final Set<String> _on;

  @override
  void initState() {
    super.initState();
    final cur = ref.read(settingsProvider).lyricsSources;
    _on = {...cur};
    _order = [...cur, ...defaultLyricsSources.where((k) => !cur.contains(k))];
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Lyrics sources'),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 320,
        height: 220,
        child: ReorderableListView(
          buildDefaultDragHandles: false,
          onReorder: (a, b) => setState(() {
            if (b > a) b--;
            _order.insert(b, _order.removeAt(a));
          }),
          children: [
            for (var i = 0; i < _order.length; i++)
              CheckboxListTile(
                key: ValueKey(_order[i]),
                value: _on.contains(_order[i]),
                onChanged: (v) => setState(() => v == true ? _on.add(_order[i]) : _on.remove(_order[i])),
                title: Text(lyricsSourceNames[_order[i]] ?? _order[i]),
                subtitle: Text(switch (_order[i]) {
                  'lrclib' => 'Synced, open database',
                  'netease' => 'Synced, big catalogue',
                  _ => 'Plain text',
                }),
                secondary: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                controlAffinity: ListTileControlAffinity.leading,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            ref.read(settingsProvider.notifier).update({'lyricsSources': _order.where(_on.contains).toList()});
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
