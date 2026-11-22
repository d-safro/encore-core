import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:home_widget/home_widget.dart';

import '../../core/appearance.dart';
import '../../core/platform.dart';
import '../../core/settings.dart';
import '../../data/mixes.dart';
import '../../data/audiobooks.dart';
import '../../data/lyrics_translation.dart';
import '../../data/account.dart';
import '../../data/cover_cache.dart';
import '../../data/saved_covers.dart';
import '../../data/episode_alerts.dart';
import '../../data/updates.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../data/online_lyrics.dart';
import '../../playback/desktop_audio.dart';
import '../../playback/fetching.dart';
import '../../playback/dj.dart' show djChoices;
import '../../playback/handler.dart';
import '../../playback/private_session.dart';
import '../actions.dart';
import '../update.dart';
import '../download_quality.dart';
import '../usb_card.dart';
import '../../data/local_link.dart';
import '../../data/usb_link.dart';
import 'audiobooks.dart' show showAbsSignIn;
import '../widgets.dart';
import 'login.dart';
import '../../data/devices.dart';
import '../../data/pairing.dart';
import '../../data/subsonic.dart';
import '../../desktop/desktop_settings.dart';

const _formats = {'raw': 'Original', 'opus': 'Opus', 'mp3': 'MP3', 'aac': 'AAC'};
const _bitrates = [64, 96, 128, 160, 192, 256, 320];

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final creds = ref.watch(accountProvider).value;
    final sync = ref.watch(syncProvider);
    void set(String k, Object v) => n.update({k: v});
    final privateUntil = ref.watch(privateSessionProvider);
    final privateOn = privateSessionOn(privateUntil, DateTime.now());

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // a wide window: settings in a readable column
      body: _Readable(
        child: ListView(
        children: [
          const SectionTitle('Server'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(creds?.base ?? ''),
            subtitle: Text('Signed in as ${creds?.username ?? ''}'),
            trailing: TextButton(
              onPressed: () async {
                if (await confirm(context, 'Sign out?', 'Downloads stay on the $deviceWord.', ok: 'Sign out')) {
                  await ref.read(accountProvider.notifier).signOut(beforeSwitch: audioHandler.leaveServer);
                  await audioHandler.enterServer();
                }
              },
              child: const Text('Sign out'),
            ),
          ),
          const _HomeAddress(),
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
            title: Text('Save library on the $deviceWord'),
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
            secondary: const Icon(Icons.bolt_rounded),
            title: const Text('Get songs you don\'t have automatically'),
            subtitle: ValueListenableBuilder(
              valueListenable: audioHandler.fetcher.rulesNow,
              builder: (_, r, _) {
                if (r == null && s.showLookup) audioHandler.fetcher.loadRules();
                return Text(trialRules(r));
              },
            ),
            value: s.autoGetSongs,
            onChanged: s.showLookup ? (v) => set('autoGetSongs', v) : null,
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
          ListTile(
            leading: const Icon(Icons.translate_rounded),
            title: const Text('Translate lyrics into'),
            subtitle: Text(
              '${s.lyricsLanguage.isEmpty ? 'Your phone\'s language (${lyricsLanguages[lyricsTargetLanguage('')]})' : lyricsLanguages[s.lyricsLanguage] ?? s.lyricsLanguage}'
              ' · by your server\'s AI, nothing leaves home',
            ),
            onTap: () async {
              final v = await showDialog<String>(
                context: context,
                builder: (ctx) => SimpleDialog(
                  title: const Text('Translate lyrics into'),
                  children: [
                    for (final e in {'': 'Your phone\'s language', ...lyricsLanguages}.entries)
                      ListTile(
                        title: Text(e.value),
                        trailing: e.key == s.lyricsLanguage ? const Icon(Icons.check_rounded) : null,
                        onTap: () => Navigator.pop(ctx, e.key),
                      ),
                  ],
                ),
              );
              if (v != null) set('lyricsLanguage', v);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.stadium_outlined),
            title: const Text('Concerts near you'),
            subtitle: const Text('A notification when an artist you play or follow announces a show near you'),
            value: prefs.getBool('concertAlerts') ?? true,
            onChanged: (v) async {
              await prefs.setBool('concertAlerts', v);
              if (v) await askNotificationPermission(prefs);
              ref.invalidate(settingsProvider); // redraw
            },
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
            secondary: Icon(Icons.lock_outline_rounded, color: privateOn ? Theme.of(context).colorScheme.primary : null),
            title: const Text('Private session'),
            subtitle: Text(privateSessionLabel(privateUntil)),
            value: privateOn,
            onChanged: (v) => ref.read(privateSessionProvider.notifier).set(v),
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

          const _MixesSettings(),
          const SectionTitle('Audiobooks'),
          Builder(builder: (context) {
            final abs = ref.watch(absAccountProvider);
            return abs == null
                ? ListTile(
                    leading: const Icon(Icons.headphones_outlined),
                    title: const Text('Sign in to Audiobookshelf'),
                    subtitle: const Text('Your audiobooks in an Audiobooks tab, with your place kept on the server'),
                    onTap: () => showAbsSignIn(context, ref),
                  )
                : ListTile(
                    leading: const Icon(Icons.headphones_rounded),
                    title: Text('Audiobookshelf · ${abs.user}'),
                    subtitle: Text(abs.base),
                    trailing: TextButton(
                      onPressed: () => ref.read(absAccountProvider.notifier).signOut(),
                      child: const Text('Sign out'),
                    ),
                  );
          }),
          const SectionTitle('Your devices'),
          const _DevicesSettings(),
          if (isDesktop) ...[
            const SectionTitle('Desktop'),
            const DesktopSettings(),
          ],

          const SectionTitle('Look'),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Appearance'),
            subtitle: Text(
              '${lookOf(s)?.label ?? 'Custom'} look · colours, text, Home, player and tabs',
            ),
            onTap: () => context.push('/appearance'),
          ),
          if (!isDesktop) ListTile(
            leading: const Icon(Icons.widgets_outlined),
            title: const Text('Add the widget to your home screen'),
            subtitle: const Text('What\'s playing, with play, pause and skip'),
            onTap: () => HomeWidget.requestPinWidget(qualifiedAndroidName: 'dev.safro.encore.EncoreWidget'),
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
          SwitchListTile(
            secondary: const Icon(Icons.record_voice_over_outlined),
            title: const Text('DJ'),
            subtitle: Text(s.dj
                ? 'Says a line about the next song ${s.djEvery == 1 ? 'before every song' : 'every ${s.djEvery} songs'}, over its start. Needs your server\'s AI to be on'
                : 'A line about the next song now and then, written and read by your server\'s AI (when it\'s on)'),
            value: s.dj,
            onChanged: (v) => set('dj', v),
          ),
          if (s.dj)
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
              child: SegmentedButton<int>(
                segments: [for (final n in djChoices) ButtonSegment(value: n, label: Text(n == 1 ? 'Every song' : 'Every $n'))],
                selected: {s.djEvery},
                showSelectedIcon: false,
                onSelectionChanged: (v) => set('djEvery', v.first),
              ),
            ),
          SwitchListTile(
            secondary: const Icon(Icons.auto_fix_high_outlined),
            title: const Text('Automix'),
            subtitle: const Text('The next song comes in where this one starts to fade, for a few bars at its '
                'tempo; silence at the ends is cut. Uses your server\'s analysis, else the crossfade above'),
            value: s.automix,
            onChanged: (v) => set('automix', v),
          ),
          if (s.crossfade > 0 || s.automix)
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
            title: const Text('Autoplay'),
            subtitle: const Text('When what you play runs out, keep going with songs like it'),
            value: s.autoplay,
            onChanged: (v) => set('autoplay', v),
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
          if (!isDesktop) const _AppIconPicker(),
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
      ),
    );
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
      _bytes == null ? 'Covers and artist photos kept on the $deviceWord' : '${(_bytes! / 1048576).toStringAsFixed(0)} MB of covers and artist photos',
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

  EqParams? _params;
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
    if (isDesktop) {
      _params = EqParams.desktop(ref.read(settingsProvider).eqGains);
      return;
    }
    audioHandler.equalizer.parameters
        .timeout(const Duration(seconds: 4))
        .then((p) => _safeSetState(() => _params = EqParams.android(p)))
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
  late Future<int> _covers = savedCovers?.bytes() ?? Future.value(0); // pictures kept with the downloads

  /// Songs in the library, and the space they'd take at the download quality (original sizes for Lossless).
  Future<(int, int)> _librarySize() async {
    final all = await ref.read(dbProvider).allSongs();
    final set = ref.read(settingsProvider);
    final raw = set.downloadFormat == 'raw';
    return (
      all.length,
      all.fold<int>(0, (n, x) => n + (raw ? (x.size ?? 0) : DownloadsNotifier.sizeAt(x, set.downloadBitrate))),
    );
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
        await confirm(context, 'Remove $what from the $deviceWord?', 'Everything stays on your server.', ok: 'Remove')) {
      await n.unpin(key, list);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(downloadsProvider, (a, b) {
      if (a?.files.length != b.files.length) _safeSetState(() => _future = ref.read(dbProvider).downloads());
    });
    final dl = ref.watch(downloadsProvider);
    // files added, removed or swapped for smaller copies: read the list (and sizes) again
    ref.listen(downloadsProvider.select((d) => d.files), (prev, next) {
      if (prev != next) {
        setState(() {
          _future = ref.read(dbProvider).downloads();
          _covers = savedCovers?.bytes() ?? Future.value(0);
        });
      }
    });
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
                    Text('${nSongs(list.length)} on this $deviceWord', style: t.headlineSmall),
                    FutureBuilder(
                      future: _covers,
                      builder: (_, pics) => Text(
                        '${_gb(bytes + (pics.data ?? 0))} used${dl.progress.isNotEmpty ? ' · ${dl.progress.length} downloading' : ''}'
                        '${ref.watch(settingsProvider).downloadWifiOnly ? ' · Wi-Fi only' : ''}'
                        '${(pics.data ?? 0) > 0 ? '\nIncludes ${_gb(pics.data!)} of covers, so they show offline' : ''}',
                        style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      ),
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
              if (!isDesktop) const UsbCard(),
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
                        'Frees the space on the $deviceWord. Your server keeps everything.',
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

/// The server's address on your home network: on the same Wi-Fi, Encore goes there directly (no VPN).
class _HomeAddress extends ConsumerWidget {
  const _HomeAddress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final address = ref.watch(localAddressProvider);
    final home = ref.watch(localLinkProvider);
    final cable = ref.watch(usbLinkProvider);
    final via = cable ? 'Connected by USB cable' : (home ? 'Connected on your home network' : null);
    return ListTile(
      leading: Icon(cable ? Icons.usb_rounded : Icons.home_outlined),
      title: const Text('Address on your home network'),
      subtitle: Text(
        address.isEmpty
            ? 'Optional. On the same Wi-Fi as your server, music goes straight there, no VPN needed'
            : [address, ?via].join(' · '),
      ),
      onTap: () => _edit(context, ref, address),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, String current) async {
    final text = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('Address on your home network'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The address your server answers on at home, e.g. https://lan-music.example.com:4541 or '
              'http://192.168.1.20:4533. Encore uses it whenever it answers, and the main address otherwise.'
              '${isDesktop ? '\n\nThis computer runs the server? Use its own address, e.g. http://127.0.0.1:4540 '
                  '(with the server extras) or http://127.0.0.1:4533 (Navidrome alone).' : ''}',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: text,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(hintText: 'https://…', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          if (current.isNotEmpty) TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, text.text), child: const Text('Save')),
        ],
      ),
    );
    if (result == null) return;
    final creds = ref.read(accountProvider).value;
    await ref.read(localAddressProvider.notifier).set(result);
    if (result.trim().isEmpty || creds == null || !context.mounted) return;
    final ok = await LocalLinkNotifier.answers(creds, result);
    if (!context.mounted) return;
    toast(
      context,
      ok
          ? 'Your server answers there: Encore uses it on this network'
          : "Saved. Your server doesn't answer there right now; Encore tries again on Wi-Fi",
    );
    ref.read(localLinkProvider.notifier).check();
  }
}

/// This device's name on your others, phone sign-in for another device, and the switch for it all.
class _DevicesSettings extends ConsumerWidget {
  const _DevicesSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(devicesProvider);
    final on = prefs.getBool('connectDevices') ?? true;
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.devices_rounded),
          title: const Text('Connect to your other devices'),
          subtitle: Text(switch (st.supported) {
            false => 'Your server doesn\'t have the extras for this (music-lookup)',
            _ when !on => 'Off: your devices don\'t see this one',
            _ => st.online.isEmpty
                ? 'See what they play, control them, move playback (none open right now)'
                : 'Open now: ${st.online.map((d) => d.name).join(', ')}',
          }),
          value: on,
          onChanged: (v) async {
            if (!v) await ref.read(devicesProvider.notifier).bye();
            await prefs.setBool('connectDevices', v);
            ref.invalidate(devicesProvider);
          },
        ),
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('This device\'s name'),
          subtitle: Text(deviceName()),
          onTap: () async {
            final name = await askText(context, 'This device\'s name', 'Name', initial: deviceName());
            if (name == null) return;
            await prefs.setString('deviceName', name.trim());
            ref.invalidate(devicesProvider); // says hello again with the new name
          },
        ),
        ListTile(
          leading: const Icon(Icons.phonelink_lock_rounded),
          title: const Text('Sign in another device'),
          subtitle: const Text('Type the code it shows (Sign in with another device)'),
          onTap: () => _approve(context, ref),
        ),
      ],
    );
  }

  Future<void> _approve(BuildContext context, WidgetRef ref) async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    final code = await askText(context, 'Sign in another device', 'The 6-digit code it shows');
    if (code == null || code.trim().isEmpty || !context.mounted) return;
    try {
      final name = await approvePairing(c, code, localAddress: ref.read(localAddressProvider));
      if (context.mounted) toast(context, 'Signed in on $name');
    } on SubsonicException catch (e) {
      if (context.mounted) toast(context, e.message);
    } catch (e) {
      if (context.mounted) toast(context, "Couldn't reach the server: $e");
    }
  }
}

/// At most ~860 px wide, centred (desktop and tablets); phones are narrower anyway.
class _Readable extends StatelessWidget {
  const _Readable({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 860), child: child),
  );
}

/// Settings › Your mixes: each kind on or off (made on the server; off deletes its playlists).
class _MixesSettings extends ConsumerStatefulWidget {
  const _MixesSettings();
  @override
  ConsumerState<_MixesSettings> createState() => _MixesSettingsState();
}

class _MixesSettingsState extends ConsumerState<_MixesSettings> {
  final _busy = <String>{};

  @override
  Widget build(BuildContext context) {
    final m = ref.watch(mixesProvider).value;
    if (m == null || !m.supported) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Your mixes'),
        for (final k in mixNames.keys)
          SwitchListTile(
            secondary: Icon(switch (k) {
              'discover' => Icons.explore_outlined,
              'radar' => Icons.new_releases_outlined,
              'daylist' => Icons.wb_twilight_rounded,
              _ => Icons.queue_music_rounded,
            }),
            title: Text(mixNames[k]!),
            subtitle: Text(mixAbout[k]!),
            value: m.isOn(k),
            onChanged: _busy.contains(k)
                ? null
                : (v) async {
                    setState(() => _busy.add(k));
                    try {
                      await setMixOn(ref, k, v);
                    } catch (e) {
                      if (context.mounted) toast(context, 'Couldn\'t change ${mixNames[k]}: $e');
                    } finally {
                      if (mounted) setState(() => _busy.remove(k));
                    }
                  },
          ),
      ],
    );
  }
}
