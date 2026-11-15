import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ThemeSource { wallpaper, albumArt, fixed }

enum ReplayGainMode { off, track, album, auto }

enum AlbumSort { recent, newest, alphabetical, artist, year, frequent, random, starred }

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
  final double speed;
  final bool endlessRadio; // keep the music going with sound-alikes when the queue ends
  final bool scrobble;
  final bool syncPlayQueue; // save the queue on the server (continue on another device)
  final bool onlineLyrics; // LRCLIB when the server has no lyrics
  final bool showLookup; // show songs you don't have (music-lookup) in search and album pages
  final bool offlineMode;
  final AlbumSort albumSort;
  final bool albumGrid;
  final int sleepMinutes;
  final List<String> homeSections;
  final bool eqEnabled;
  final List<double> eqGains; // dB per band
  final int cacheMb;

  const Settings({
    this.themeSource = ThemeSource.wallpaper,
    this.accentColor = 0xFF6750A4,
    this.pureBlack = false,
    this.wifiFormat = 'raw',
    this.mobileFormat = 'opus',
    this.wifiBitrate = 0,
    this.mobileBitrate = 128,
    this.downloadFormat = 'raw',
    this.downloadBitrate = 0,
    this.downloadWifiOnly = true,
    this.replayGain = ReplayGainMode.auto,
    this.replayGainPreamp = 0,
    this.skipSilence = false,
    this.speed = 1.0,
    this.endlessRadio = false,
    this.scrobble = true,
    this.syncPlayQueue = true,
    this.onlineLyrics = true,
    this.showLookup = true,
    this.offlineMode = false,
    this.albumSort = AlbumSort.recent,
    this.albumGrid = true,
    this.sleepMinutes = 30,
    this.homeSections = defaultHomeSections,
    this.eqEnabled = false,
    this.eqGains = const [],
    this.cacheMb = 1024,
  });

  static const defaultHomeSections = ['recent', 'newest', 'frequent', 'starred', 'random', 'playlists'];

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
        'speed': speed,
        'endlessRadio': endlessRadio,
        'scrobble': scrobble,
        'syncPlayQueue': syncPlayQueue,
        'onlineLyrics': onlineLyrics,
        'showLookup': showLookup,
        'offlineMode': offlineMode,
        'albumSort': albumSort.name,
        'albumGrid': albumGrid,
        'sleepMinutes': sleepMinutes,
        'homeSections': homeSections,
        'eqEnabled': eqEnabled,
        'eqGains': eqGains,
        'cacheMb': cacheMb,
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
      speed: (j['speed'] as num?)?.toDouble() ?? d.speed,
      endlessRadio: j['endlessRadio'] ?? d.endlessRadio,
      scrobble: j['scrobble'] ?? d.scrobble,
      syncPlayQueue: j['syncPlayQueue'] ?? d.syncPlayQueue,
      onlineLyrics: j['onlineLyrics'] ?? d.onlineLyrics,
      showLookup: j['showLookup'] ?? d.showLookup,
      offlineMode: j['offlineMode'] ?? d.offlineMode,
      albumSort: pick(AlbumSort.values, j['albumSort'], d.albumSort),
      albumGrid: j['albumGrid'] ?? d.albumGrid,
      sleepMinutes: j['sleepMinutes'] ?? d.sleepMinutes,
      homeSections: (j['homeSections'] as List?)?.cast<String>().where((x) => x != 'mixes').toList() ?? d.homeSections,
      eqEnabled: j['eqEnabled'] ?? d.eqEnabled,
      eqGains: (j['eqGains'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? d.eqGains,
      cacheMb: j['cacheMb'] ?? d.cacheMb,
    );
  }

  Settings copyWith(Map<String, dynamic> changes) => Settings.fromJson({...toJson(), ...changes});
}

late SharedPreferences prefs; // set in main() before runApp

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
