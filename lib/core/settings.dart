import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ThemeSource { wallpaper, albumArt, fixed }

enum ReplayGainMode { off, track, album, auto }

enum AlbumSort { recent, newest, alphabetical, artist, year, frequent, random, starred }

// ── Appearance (Settings → Appearance; the looks that bundle these are in appearance.dart) ──

/// How round corners are: covers, cards, the mini player, sheets.
enum Corners { square, small, soft, round }

/// How big album cards are on shelves and in the library grid.
enum CardSize { small, medium, large }

/// The player screen: a big cover; a smaller cover with the lyrics under it; or a small cover and big titles.
enum PlayerLayout { bigCover, coverLyrics, minimal }

/// The blurred copy of the artwork behind the player.
enum PlayerBlur { off, soft, strong }

/// The bar above the tabs: a floating card, a flat full-width strip, or a thinner card without the heart.
enum MiniPlayerStyle { floating, flat, slim }

/// Names under the bottom tabs.
enum NavLabels { always, selected, never }

/// Every user setting, stored as one JSON blob in shared preferences.
class Settings {
  final ThemeSource themeSource;
  final int accentColor; // used when themeSource == fixed (and as fallback)
  final bool pureBlack; // AMOLED black backgrounds

  // Streaming quality: "raw" = original file, else a server transcode target.
  final String wifiFormat, mobileFormat;
  final int wifiBitrate, mobileBitrate;
  final String downloadFormat;
  final int downloadBitrate;
  final bool downloadWifiOnly;

  final ReplayGainMode replayGain;
  final double replayGainPreamp; // dB
  final bool skipSilence;
  final int crossfade; // seconds the end of a song overlaps the next (0 = off)
  final bool crossfadeAlbums; // also between songs of an album played in order (else those stay gapless)
  final double speed;
  final bool autoplay; // when what you play runs out, keep going with songs like it (see playback/autoplay.dart)
  final bool scrobble;
  final bool syncPlayQueue; // save the queue on the server (continue on another device)
  final bool onlineLyrics; // look online when the server has no lyrics
  final List<String> lyricsSources; // enabled online lyrics sources, in order (see online_lyrics.dart)
  final bool onlineCovers; // iTunes / Deezer art when the server has none
  final double pitch;
  final bool showLookup; // show songs you don't have (music-lookup) in search and album pages
  // playing or queueing a song you don't have gets it on trial straight away (off: ask first)
  final bool autoGetSongs;
  final bool offlineMode;
  final AlbumSort albumSort;
  final bool albumGrid;
  final int sleepMinutes;
  final List<String> homeSections;
  final bool eqEnabled;
  final List<double> eqGains; // dB per band
  final int cacheMb;

  // Appearance
  final bool highContrast; // brighter secondary text and clearer edges between surfaces
  final String fontFamily; // 'inter' (Encore's) or 'system' (the phone's)
  final double textScale; // on top of the phone's own text size
  final Corners corners;
  final bool compact; // tighter rows and buttons
  final CardSize cardSize;
  final bool showQuickPills, showJumpBackIn, showGreeting; // parts of Home
  final PlayerLayout playerLayout;
  final PlayerBlur playerBlur;
  final MiniPlayerStyle miniPlayer;
  final List<String> navTabs; // the bottom tabs, in order (Home always stays)
  final NavLabels navLabels;

  const Settings({
    this.themeSource = ThemeSource.wallpaper,
    this.accentColor = 0xFF6750A4,
    this.pureBlack = false,
    this.wifiFormat = 'raw',
    this.mobileFormat = 'opus',
    this.wifiBitrate = 0,
    this.mobileBitrate = 128,
    this.downloadFormat = 'opus',
    this.downloadBitrate = 160,
    this.downloadWifiOnly = true,
    this.replayGain = ReplayGainMode.auto,
    this.replayGainPreamp = 0,
    this.skipSilence = false,
    this.crossfade = 0,
    this.crossfadeAlbums = false,
    this.speed = 1.0,
    this.autoplay = true,
    this.scrobble = true,
    this.syncPlayQueue = true,
    this.onlineLyrics = true,
    this.lyricsSources = const ['lrclib', 'netease', 'ovh'],
    this.onlineCovers = true,
    this.pitch = 1.0,
    this.showLookup = true,
    this.autoGetSongs = true,
    this.offlineMode = false,
    this.albumSort = AlbumSort.recent,
    this.albumGrid = true,
    this.sleepMinutes = 30,
    this.homeSections = defaultHomeSections,
    this.eqEnabled = false,
    this.eqGains = const [],
    this.cacheMb = 1024,
    this.highContrast = false,
    this.fontFamily = 'inter',
    this.textScale = 1.0,
    this.corners = Corners.soft,
    this.compact = false,
    this.cardSize = CardSize.medium,
    this.showQuickPills = true,
    this.showJumpBackIn = true,
    this.showGreeting = true,
    this.playerLayout = PlayerLayout.bigCover,
    this.playerBlur = PlayerBlur.soft,
    this.miniPlayer = MiniPlayerStyle.floating,
    this.navTabs = defaultNavTabs,
    this.navLabels = NavLabels.selected,
  });

  static const defaultHomeSections = ['recent', 'newest', 'frequent', 'starred', 'random', 'playlists'];
  static const defaultNavTabs = ['home', 'discover', 'library', 'search'];

  Map<String, dynamic> toJson() => {
    'themeSource': themeSource.name,
    'accentColor': accentColor,
    'pureBlack': pureBlack,
    'wifiFormat': wifiFormat,
    'mobileFormat': mobileFormat,
    'wifiBitrate': wifiBitrate,
    'mobileBitrate': mobileBitrate,
    'downloadFormat': downloadFormat,
    'downloadBitrate': downloadBitrate,
    'downloadWifiOnly': downloadWifiOnly,
    'replayGain': replayGain.name,
    'replayGainPreamp': replayGainPreamp,
    'skipSilence': skipSilence,
    'crossfade': crossfade,
    'crossfadeAlbums': crossfadeAlbums,
    'speed': speed,
    'autoplay': autoplay,
    'scrobble': scrobble,
    'syncPlayQueue': syncPlayQueue,
    'onlineLyrics': onlineLyrics,
    'lyricsSources': lyricsSources,
    'onlineCovers': onlineCovers,
    'pitch': pitch,
    'showLookup': showLookup,
    'autoGetSongs': autoGetSongs,
    'offlineMode': offlineMode,
    'albumSort': albumSort.name,
    'albumGrid': albumGrid,
    'sleepMinutes': sleepMinutes,
    'homeSections': homeSections,
    'eqEnabled': eqEnabled,
    'eqGains': eqGains,
    'cacheMb': cacheMb,
    'highContrast': highContrast,
    'fontFamily': fontFamily,
    'textScale': textScale,
    'corners': corners.name,
    'compact': compact,
    'cardSize': cardSize.name,
    'showQuickPills': showQuickPills,
    'showJumpBackIn': showJumpBackIn,
    'showGreeting': showGreeting,
    'playerLayout': playerLayout.name,
    'playerBlur': playerBlur.name,
    'miniPlayer': miniPlayer.name,
    'navTabs': navTabs,
    'navLabels': navLabels.name,
  };

  factory Settings.fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, dynamic name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    const d = Settings();
    return Settings(
      themeSource: pick(ThemeSource.values, j['themeSource'], d.themeSource),
      accentColor: j['accentColor'] ?? d.accentColor,
      pureBlack: j['pureBlack'] ?? d.pureBlack,
      wifiFormat: j['wifiFormat'] ?? d.wifiFormat,
      mobileFormat: j['mobileFormat'] ?? d.mobileFormat,
      wifiBitrate: j['wifiBitrate'] ?? d.wifiBitrate,
      mobileBitrate: j['mobileBitrate'] ?? d.mobileBitrate,
      downloadFormat: j['downloadFormat'] ?? d.downloadFormat,
      downloadBitrate: j['downloadBitrate'] ?? d.downloadBitrate,
      downloadWifiOnly: j['downloadWifiOnly'] ?? d.downloadWifiOnly,
      replayGain: pick(ReplayGainMode.values, j['replayGain'], d.replayGain),
      replayGainPreamp: (j['replayGainPreamp'] as num?)?.toDouble() ?? d.replayGainPreamp,
      skipSilence: j['skipSilence'] ?? d.skipSilence,
      crossfade: (j['crossfade'] as num?)?.toInt() ?? d.crossfade,
      crossfadeAlbums: j['crossfadeAlbums'] ?? d.crossfadeAlbums,
      speed: (j['speed'] as num?)?.toDouble() ?? d.speed,
      autoplay: j['autoplay'] ?? d.autoplay,
      scrobble: j['scrobble'] ?? d.scrobble,
      syncPlayQueue: j['syncPlayQueue'] ?? d.syncPlayQueue,
      onlineLyrics: j['onlineLyrics'] ?? d.onlineLyrics,
      lyricsSources: (j['lyricsSources'] as List?)?.map((e) => '$e').toList() ?? d.lyricsSources,
      onlineCovers: j['onlineCovers'] ?? d.onlineCovers,
      pitch: (j['pitch'] as num?)?.toDouble() ?? d.pitch,
      showLookup: j['showLookup'] ?? d.showLookup,
      autoGetSongs: j['autoGetSongs'] ?? d.autoGetSongs,
      offlineMode: j['offlineMode'] ?? d.offlineMode,
      albumSort: pick(AlbumSort.values, j['albumSort'], d.albumSort),
      albumGrid: j['albumGrid'] ?? d.albumGrid,
      sleepMinutes: j['sleepMinutes'] ?? d.sleepMinutes,
      homeSections: (j['homeSections'] as List?)?.cast<String>().where((x) => x != 'mixes').toList() ?? d.homeSections,
      eqEnabled: j['eqEnabled'] ?? d.eqEnabled,
      eqGains: (j['eqGains'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? d.eqGains,
      cacheMb: j['cacheMb'] ?? d.cacheMb,
      highContrast: j['highContrast'] ?? d.highContrast,
      fontFamily: j['fontFamily'] == 'system' ? 'system' : 'inter',
      textScale: ((j['textScale'] as num?)?.toDouble() ?? d.textScale).clamp(0.8, 1.4),
      corners: pick(Corners.values, j['corners'], d.corners),
      compact: j['compact'] ?? d.compact,
      cardSize: pick(CardSize.values, j['cardSize'], d.cardSize),
      showQuickPills: j['showQuickPills'] ?? d.showQuickPills,
      showJumpBackIn: j['showJumpBackIn'] ?? d.showJumpBackIn,
      showGreeting: j['showGreeting'] ?? d.showGreeting,
      playerLayout: pick(PlayerLayout.values, j['playerLayout'], d.playerLayout),
      playerBlur: pick(PlayerBlur.values, j['playerBlur'], d.playerBlur),
      miniPlayer: pick(MiniPlayerStyle.values, j['miniPlayer'], d.miniPlayer),
      navTabs: _cleanTabs(j['navTabs']),
      navLabels: pick(NavLabels.values, j['navLabels'], d.navLabels),
    );
  }

  Settings copyWith(Map<String, dynamic> changes) => Settings.fromJson({...toJson(), ...changes});

  /// Known tabs only, no repeats, Home always there, at least two.
  static List<String> _cleanTabs(dynamic raw) {
    final tabs = <String>[];
    for (final t in (raw as List?) ?? defaultNavTabs) {
      if (defaultNavTabs.contains(t) && !tabs.contains(t)) tabs.add('$t');
    }
    if (!tabs.contains('home')) tabs.insert(0, 'home');
    if (tabs.length < 2) tabs.add(defaultNavTabs.firstWhere((t) => !tabs.contains(t)));
    return tabs;
  }
}

late SharedPreferences prefs; // set in main() before runApp

/// Download quality, like Spotify's levels (which use Ogg Vorbis at ~24 / 96 / 160 / 320 kbps). Opus sounds
/// better than Vorbis at the same size, so these match Spotify's quality in less space.
/// (name, format, kbps, what it means)
const downloadLevels = [
  ('Low', 'opus', 48, 'About 22 MB an hour. Fine for talk and background music'),
  ('Normal', 'opus', 96, 'About 43 MB an hour'),
  ('High', 'opus', 160, 'About 72 MB an hour. Sounds like the original to almost everyone'),
  ('Very high', 'opus', 256, 'About 115 MB an hour'),
  ('Lossless', 'raw', 0, 'The original files: FLAC is 250–600 MB an hour, hi-res more'),
];

/// The level for a format + bitrate, or null for a custom one.
(String, String, int, String)? downloadLevelOf(String format, int kbps) {
  for (final l in downloadLevels) {
    if (l.$2 == format && (format == 'raw' || l.$3 == kbps)) return l;
  }
  return null;
}

/// Shown in Settings. Keep in step with `version:` in pubspec.yaml.
const appVersion = '1.8.0';

class SettingsNotifier extends Notifier<Settings> {
  static const _key = 'settings';

  @override
  Settings build() {
    final raw = prefs.getString(_key);
    if (raw == null) return const Settings();
    try {
      return Settings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const Settings();
    }
  }

  void update(Map<String, dynamic> changes) {
    state = state.copyWith(changes);
    prefs.setString(_key, jsonEncode(state.toJson()));
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);
