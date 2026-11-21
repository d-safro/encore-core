import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import 'automix.dart';
import 'autoplay.dart';
import 'cast.dart';
import 'desktop_audio.dart';
import 'fetching.dart';
import 'private_session.dart';
import '../core/platform.dart';
import '../core/settings.dart';
import '../data/account.dart';
import '../data/ai.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/saved_covers.dart';
import '../data/subsonic.dart';

/// Extra state the UI shows next to the standard playback state.
class PlayerExtras {
  final DateTime? sleepAt; // pause at this time
  final bool sleepAfterTrack;
  final double speed;
  const PlayerExtras({this.sleepAt, this.sleepAfterTrack = false, this.speed = 1.0});
}

/// Off, normal shuffle, or smart shuffle (shuffle plus songs that fit, about one every three songs).
enum ShuffleKind { off, on, smart }

/// Where the queue came from, so a smart-shuffle pick can be saved into it.
class PlayContext {
  const PlayContext(this.kind, {this.id = '', this.name = ''});
  const PlayContext.playlist(String id, String name) : this('playlist', id: id, name: name);
  const PlayContext.album(String id, String name) : this('album', id: id, name: name);
  const PlayContext.liked() : this('starred', name: 'Liked songs');

  final String kind; // playlist, album, starred
  final String id, name;
  String get key => '$kind:$id';

  Map<String, dynamic> toJson() => {'kind': kind, 'id': id, 'name': name};
  static PlayContext? fromJson(Object? j) =>
      j is Map ? PlayContext('${j['kind'] ?? ''}', id: '${j['id'] ?? ''}', name: '${j['name'] ?? ''}') : null;
}

/// The one playback engine: a just_audio player behind audio_service, so playback keeps going in the
/// background with the media notification, lock-screen and Bluetooth controls and Android Auto. On the
/// desktop the player is mpv and audio_service speaks MPRIS (Plasma's media controls, media keys).
class EncoreAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  EncoreAudioHandler(this.container) {
    _init();
  }

  final ProviderContainer container;
  final equalizer = AndroidEqualizer();
  final loudness = AndroidLoudnessEnhancer();
  late final AudioPlayer player = isDesktop
      ? AudioPlayer() // the equalizer and loudness are mpv filters there (desktop_audio.dart)
      : AudioPlayer(audioPipeline: AudioPipeline(androidAudioEffects: [equalizer, loudness]));

  final List<Song> _songs = []; // same order as the player's sequence
  List<Song> get songs => List.unmodifiable(_songs);
  final extras = StreamController<PlayerExtras>.broadcast();
  PlayerExtras _extras = const PlayerExtras();
  PlayerExtras get currentExtras => _extras;

  Timer? _sleepTimer, _saveTimer, _periodicSave;
  String? _lastSongId;
  String? _scrobbledNow, _submitted;
  Duration _listened = Duration.zero;
  DateTime? _lastTick;
  Song? radioSeed; // set while a song radio is playing: the queue keeps growing with songs like it

  // ── Autoplay (see autoplay.dart): when what you chose runs out, songs like it keep coming ──
  final Set<String> _autoplay = {}; // queue songs autoplay added (not what you chose)
  bool isAutoplay(String id) => _autoplay.contains(id);
  Song? autoplaySeed; // the song the latest autoplay songs are like, for "Songs like …"
  bool _autoFilling = false;
  int _queueGen = 0; // goes up when a new queue replaces the old one (a slow fetch for the old one is dropped)
  final Set<String> _autoUsed = {}; // suggested already this session
  final List<Song> _history = []; // the last songs played, oldest first
  final List<Song> _queueHistory = []; // the songs played since this queue started (autoplay follows these)
  Song? _nowSong; // the song playing (for skip counting when it changes)
  DateTime? _userMoveAt; // when you last skipped (next, previous, a queue tap)
  bool _movedForward = false;
  int _nowGen = 0;
  String? _playCounted;
  SkipStats? _skipStats;
  SkipStats get _skips =>
      _skipStats ??= SkipStats.fromJson(_tryJson(prefs.getString('skipStats')));
  (DateTime, List<Song>)? _favCache, _freqCache;

  // ── Shuffle (done by reordering the queue, so the queue always shows the real play order) ──
  ShuffleKind _shuffleKind = ShuffleKind.off;
  ShuffleKind get shuffleKind => _shuffleKind;
  List<Song>? _original; // the order to go back to when shuffle is switched off
  final Set<String> _suggested = {}; // songs smart shuffle added
  final Set<String> _usedPicks = {}; // picked already this session (not suggested twice)
  final List<Song> _pickPool = []; // fetched picks not placed yet
  PlayContext? playContext;
  String? playSource; // which page's songs are playing (album:<id>, playlist:<id>, …), for its play button
  bool _rearranging = false, _filling = false, _smartNoticeShown = false;
  InternetRadio? radioStation; // set while an internet radio station plays
  Timer? _reportTimer;
  DateTime? _podSavedAt; // last time a podcast position was saved
  String? _podDone; // the episode last marked played
  String? _podActive; // the episode actually played this session (a restored queue mustn't overwrite newer progress)
  bool _reportsWork = true; // the server understands playback reports
  String? _reportedId, _reportedState;
  bool isSuggested(String id) => _suggested.contains(id);

  static Object? _tryJson(String? raw) {
    try {
      return raw == null ? null : jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Settings get _settings => container.read(settingsProvider);

  /// A private session is on: nothing is scrobbled, reported or learned from (see private_session.dart).
  bool get _private => container.read(privateSessionProvider.notifier).on;

  Future<void> _init() async {
    if (!isDesktop) {
      // Android's audio focus (calls and other apps pause the music); the desktop has no such thing
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    }

    player.playbackEventStream.listen(
      _broadcast,
      onError: (Object e, StackTrace st) async {
        // a song that can't be played (server gone, file missing): skip it instead of stopping
        container.read(serverReachableProvider.notifier).suspect();
        await _skipToPlayable();
      },
    );
    if (isDesktop) {
      // mpv reports a song that won't play here (just_audio's errorStream), not as an error on the events
      player.errorStream.listen((_) async {
        if (_loading) return; // _load tries the next song itself
        container.read(serverReachableProvider.notifier).suspect();
        await _skipToPlayable();
      });
    }
    // the downloader asks before deleting a file the queue may be playing from
    DownloadsNotifier.fileInUse = (id) => _onPhone.contains(id) && _songs.any((s) => s.id == id);
    player.currentIndexStream.listen(_onIndex);
    player.processingStateStream.listen((st) {
      final s = currentSong;
      if (st == ProcessingState.ready && s != null && !_onPhone.contains(s.id) && player.playing) {
        serverTrouble.value = null; // streaming works again
      }
    });
    player.sequenceStream.listen((_) => _onIndex(player.currentIndex)); // same index, different song
    player.positionStream.listen(_onPosition);
    player.icyMetadataStream.listen((m) {
      // stations that send song titles: show "Artist - Song" under the station's name
      final t = m?.info?.title?.trim() ?? '';
      final item = mediaItem.value;
      if (radioStation != null && t.isNotEmpty && item != null && item.id.startsWith('radio-')) {
        mediaItem.add(item.copyWith(artist: t));
      }
    });
    player.playingStream.distinct().listen((playing) {
      // a song you don't have that's still on its way: nothing plays until it's there (only silence would)
      if (playing && _waitingFor != null && currentSong?.id == _waitingFor) {
        player.pause();
        return;
      }
      if (!playing && _fadeFrom != null) _cancelFade(); // paused mid-blend: the rest plays plainly
      final c = _cast;
      if (c != null && c.isOpen) {
        _castCommandAt = DateTime.now();
        playing ? c.play() : c.pause();
      }
      _periodicSave?.cancel();
      _periodicSave = playing
          ? Timer.periodic(const Duration(seconds: 30), (_) {
              _saveQueue();
              _reportSoon(); // keeps the server's position honest
            })
          : null;
      if (!playing) {
        _scheduleSave(); // remember where it was paused
        _savePodcast();
      }
      _reportSoon();
    });
    player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed && _extras.sleepAfterTrack) _sleepNow();
      if (s == ProcessingState.completed && !_extras.sleepAfterTrack) _continueAfterEnd();
      if (s == ProcessingState.completed || s == ProcessingState.idle) _reportSoon();
    });
    container.listen(settingsProvider, (prev, next) => _applySettings(prev, next), fireImmediately: true);
    // going offline, or a song finishing its download: queued copies switch to the phone's file
    container.listen(privateSessionProvider, (_, _) => _reportSoon()); // clears "now playing" when it starts
    container.listen(offlineProvider, (prev, next) {
      if (next == true) useDownloadedFiles();
    });
    container.listen(downloadsProvider.select((d) => d.files.length), (prev, next) {
      if (next > (prev ?? 0)) useDownloadedFiles();
    });
    // a USB cable to the server's computer plugged in or out: queued songs stream the new way
    container.listen(clientProvider.select((c) => c?.base), (prev, next) {
      if (prev != null && next != null && prev != next) refreshStreams();
    });
    await _restoreQueue();
  }

  // ── Settings that act on the player ──
  Future<void> _applySettings(Settings? prev, Settings s) async {
    if (prev != null && prev.autoGetSongs && !s.autoGetSongs) {
      fetcher.reset(); // back to asking first; what the server is already getting carries on there
      _stopWaiting();
    }
    if (isDesktop) {
      if (prev == null) await _quiet(restoreDesktopSound);
      if (prev?.skipSilence != s.skipSilence || prev?.eqEnabled != s.eqEnabled || prev?.eqGains != s.eqGains) {
        await _quiet(() => applyDesktopSound(s));
      }
      if (prev?.speed != s.speed) await _quiet(() => setSpeed(s.speed));
      if (prev?.pitch != s.pitch) await _quiet(() => player.setPitch(s.pitch));
      if (prev?.replayGain != s.replayGain || prev?.replayGainPreamp != s.replayGainPreamp) _applyReplayGain();
      return;
    }
    if (prev?.skipSilence != s.skipSilence) await _quiet(() => player.setSkipSilenceEnabled(s.skipSilence));
    if (prev?.speed != s.speed) await _quiet(() => setSpeed(s.speed));
    if (prev?.pitch != s.pitch) await _quiet(() => player.setPitch(s.pitch));
    if (prev?.eqEnabled != s.eqEnabled) await _quiet(() => equalizer.setEnabled(s.eqEnabled));
    if (prev?.eqGains != s.eqGains && s.eqGains.isNotEmpty) {
      try {
        final params = await equalizer.parameters;
        for (var i = 0; i < params.bands.length && i < s.eqGains.length; i++) {
          await params.bands[i].setGain(s.eqGains[i].clamp(params.minDecibels, params.maxDecibels));
        }
      } catch (_) {}
    }
    if (prev?.replayGain != s.replayGain || prev?.replayGainPreamp != s.replayGainPreamp) _applyReplayGain();
    if (prev != null && prev.autoplay != s.autoplay) s.autoplay ? _keepGoing() : await _dropAutoplay();
  }

  Future<void> _quiet(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {} // audio effects can fail before the first song is loaded; they're set again later
  }

  /// Extra loudness above full volume: Android's loudness enhancer, or a gain filter in mpv. 0 switches it off.
  void _boost(double db) {
    if (isDesktop) {
      _quiet(() => setDesktopBoost(db));
    } else if (db <= 0) {
      _quiet(() => loudness.setEnabled(false));
    } else {
      _quiet(() => loudness.setTargetGain(db));
      _quiet(() => loudness.setEnabled(true));
    }
  }

  /// Volume from ReplayGain tags. Quieter-than-reference songs use the player volume; louder needs the
  /// loudness enhancer (Android can't amplify through volume alone).
  void _applyReplayGain() {
    final i = player.currentIndex;
    final s = _settings;
    if (i == null || i >= _songs.length || s.replayGain == ReplayGainMode.off) {
      _setMainVolume(1);
      _boost(0);
      return;
    }
    final song = _songs[i];
    final rg = song.replayGain;
    var albumMode = s.replayGain == ReplayGainMode.album;
    if (s.replayGain == ReplayGainMode.auto) {
      // album gain when the neighbours are from the same album (playing an album), else track gain
      final prevSame = i > 0 && _songs[i - 1].albumId == song.albumId;
      final nextSame = i + 1 < _songs.length && _songs[i + 1].albumId == song.albumId;
      albumMode = prevSame || nextSame;
    }
    final gain = (albumMode ? rg.albumGain ?? rg.trackGain : rg.trackGain ?? rg.albumGain);
    if (gain == null) {
      _setMainVolume(1);
      _boost(0);
      return;
    }
    final peak = (albumMode ? rg.albumPeak ?? rg.trackPeak : rg.trackPeak ?? rg.albumPeak) ?? 1.0;
    var db = gain + s.replayGainPreamp;
    if (peak > 0) db = min(db, -20 * log(peak) / ln10); // never push past full scale
    if (db <= 0) {
      _boost(0);
      _setMainVolume(pow(10, db / 20).toDouble());
    } else {
      _setMainVolume(1);
      _boost(db);
    }
  }

  /// The ReplayGain volume of the playing song; during a crossfade the player plays a falling share of it.
  double _mainVolume = 1, _fadeShare = 1;
  void _setMainVolume(double v) {
    _mainVolume = v;
    _quiet(() => player.setVolume(_cast != null ? 0 : v * _fadeShare)); // casting: the phone plays along silently
  }

  /// The ReplayGain volume for a song (only the quieter-than-reference part; for the crossfade player).
  double _rgVolume(int i) {
    final s = _settings;
    if (i >= _songs.length || s.replayGain == ReplayGainMode.off) return 1;
    final song = _songs[i];
    final rg = song.replayGain;
    var albumMode = s.replayGain == ReplayGainMode.album;
    if (s.replayGain == ReplayGainMode.auto) {
      albumMode = (i > 0 && _songs[i - 1].albumId == song.albumId) ||
          (i + 1 < _songs.length && _songs[i + 1].albumId == song.albumId);
    }
    final gain = albumMode ? rg.albumGain ?? rg.trackGain : rg.trackGain ?? rg.albumGain;
    if (gain == null) return 1;
    final peak = (albumMode ? rg.albumPeak ?? rg.trackPeak : rg.trackPeak ?? rg.albumPeak) ?? 1.0;
    var db = gain + s.replayGainPreamp;
    if (peak > 0) db = min(db, -20 * log(peak) / ln10);
    return db <= 0 ? pow(10, db / 20).toDouble() : 1;
  }

  // ── Crossfade ──
  // Near the end of a song the next one starts on a second player and the two cross over. When the main
  // player reaches that song itself, it picks up where the second player is and the second one stops.
  AudioPlayer? _fadePlayer;
  int? _fadeFrom; // the index fading out
  bool _fadeReady = false; // the next song is loaded on the second player
  Timer? _fadeTimer;

  bool _fadeAllowed(int i) {
    final cf = _settings.crossfade;
    if ((cf <= 0 && !_settings.automix) || _cast != null || radioStation != null || i + 1 >= _songs.length || player.loopMode == LoopMode.one) return false;
    final a = _songs[i], b = _songs[i + 1];
    if (isPodcastId(a.id) || isPodcastId(b.id) || a.isLookup || b.isLookup) return false;
    if (!canPlay(b)) return false;
    // an album played in order stays seamless (live records, DJ mixes, concept albums)
    if (!_settings.crossfadeAlbums && a.albumId.isNotEmpty && a.albumId == b.albumId && (b.track ?? 0) == (a.track ?? 0) + 1) {
      return false;
    }
    return true;
  }

  // Automix (automix.dart): what the server measured of each song, for where and how long the blend is
  final _mixInfo = <String, MixInfo>{};
  final _mixAsked = <String, DateTime>{};

  Future<void> _fetchMixInfo(int i) async {
    if (!_settings.automix || container.read(offlineProvider)) return;
    final c = container.read(clientProvider);
    if (c == null) return;
    final now = DateTime.now();
    final ids = [
      for (var k = i; k < min(i + 4, _songs.length); k++)
        if (!_mixInfo.containsKey(_songs[k].id) && !isPodcastId(_songs[k].id) && !_songs[k].isLookup &&
            now.difference(_mixAsked[_songs[k].id] ?? DateTime(0)) > const Duration(seconds: 20))
          _songs[k].id,
    ];
    if (ids.isEmpty) return;
    for (final id in ids) {
      _mixAsked[id] = now; // songs not measured yet are measured first on the server: ask again in a while
    }
    try {
      _mixInfo.addAll(await c.mixInfo(ids));
    } catch (_) {}
  }

  Transition? _plan(int i, Duration dur) => i + 1 >= _songs.length
      ? null
      : planTransition(
          length: dur,
          a: _mixInfo[_songs[i].id],
          b: _mixInfo[_songs[i + 1].id],
          automix: _settings.automix,
          crossfade: _settings.crossfade,
        );

  void _fadeTick(Duration pos) {
    if (!player.playing) return;
    final i = player.currentIndex, dur = player.duration;
    if (i == null || dur == null || dur <= Duration.zero) return;
    final left = dur - pos;
    if (_fadeFrom != null && _fadeFrom != i) _cancelFade(); // moved somewhere else
    // not measured yet (just asked, the server measures it first): ask again before it's time
    if (_settings.automix && left < const Duration(seconds: 60) && i + 1 < _songs.length &&
        (!_mixInfo.containsKey(_songs[i].id) || !_mixInfo.containsKey(_songs[i + 1].id))) {
      _fetchMixInfo(i);
    }
    final plan = _plan(i, dur);
    if (plan == null) return;
    final from = dur - plan.fadeAt; // how long before the end the blend starts
    if (_fadeFrom == null && left <= from + const Duration(seconds: 6) && left > from && _fadeAllowed(i)) {
      _prepareFade(i, plan.nextStart); // load the next song a few seconds early so the fade starts on time
    }
    if (_fadeFrom == i && _fadeReady && _fadeTimer == null && left <= from && left > const Duration(milliseconds: 500)) {
      final length = plan.length < left ? plan.length : left;
      // the blend is over before this song ends (its outro, trailing silence): move on to the next one then
      _runFade(i, length, moveOn: left - length > const Duration(seconds: 1));
    }
  }

  Future<void> _prepareFade(int i, [Duration nextStart = Duration.zero]) async {
    _fadeFrom = i;
    _fadeReady = false;
    // shares the main player's audio focus: it must not pause the main player when it starts
    final fp = _fadePlayer ??= AudioPlayer(handleInterruptions: false, handleAudioSessionActivation: false);
    try {
      await fp.setVolume(0);
      await fp.setAudioSource(_source(_songs[i + 1]), preload: true, initialPosition: nextStart);
      await fp.setSpeed(player.speed);
      if (_fadeFrom == i) _fadeReady = true;
    } catch (_) {
      if (_fadeFrom == i) _fadeFrom = null; // can't load it: no fade this time, plain gapless change
    }
  }

  void _runFade(int i, Duration left, {bool moveOn = false}) {
    final fp = _fadePlayer!;
    final start = DateTime.now();
    final target = _rgVolume(i + 1);
    fp.play();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 50), (t) {
      final x = (DateTime.now().difference(start).inMilliseconds / left.inMilliseconds).clamp(0.0, 1.0);
      // equal-power curves: the overall loudness stays even through the blend
      _fadeShare = cos(x * pi / 2);
      _quiet(() => player.setVolume(_mainVolume * _fadeShare));
      _quiet(() => fp.setVolume(target * sin(x * pi / 2)));
      if (x >= 1) {
        t.cancel();
        // Automix: the rest of this song is its faded-out tail: the next one takes over now (not a skip)
        if (moveOn && _fadeFrom == i && player.currentIndex == i) player.seekToNext();
      }
    });
  }

  /// The main player has reached the song the second player is playing: continue it from there.
  Future<void> _handOff() async {
    final fp = _fadePlayer;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _fadeFrom = null;
    if (fp == null || !fp.playing) {
      _fadeShare = 1;
      _setMainVolume(_mainVolume);
      return;
    }
    try {
      _fadeShare = 0;
      await player.setVolume(0);
      await player.seek(fp.position + const Duration(milliseconds: 120));
      await player.processingStateStream
          .firstWhere((s) => s == ProcessingState.ready)
          .timeout(const Duration(seconds: 4));
    } catch (_) {}
    _fadeShare = 1;
    _setMainVolume(_mainVolume);
    await _quiet(() => fp.stop());
  }

  void _cancelFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _fadeFrom = null;
    _fadeReady = false;
    _quiet(() async => _fadePlayer?.stop());
    if (_fadeShare != 1) {
      _fadeShare = 1;
      _setMainVolume(_mainVolume);
    }
  }

  // ── Casting (Chromecast / Google Cast) ──
  // The phone keeps playing silently and stays in charge (queue, scrobbles, lock screen); the speaker plays
  // the same song at the same place, fetched through the relay.
  CastSession? _cast;
  CastRelay? _relay;
  StreamSubscription<CastMediaStatus>? _castSub;
  Timer? _castSync;
  DateTime _castCommandAt = DateTime(0);
  (Duration, DateTime)? _castPos; // the speaker's position, and when it said so
  String _castState = 'IDLE';

  bool get casting => _cast != null;

  Future<void> startCasting(CastDevice d) async {
    if (_cast != null) await stopCasting();
    castInfo.value = CastInfo(d.name, connecting: true);
    try {
      _relay ??= await CastRelay.start();
      if (_relay == null) throw Exception('connect the $deviceWord to the same network as the speaker');
      final s = await CastSession.connect(d);
      _cast = s;
      _cancelFade();
      _setMainVolume(_mainVolume); // silences the phone
      _castSub = s.status.stream.listen(_onCastStatus);
      s.closed.future.then((_) => _castEnded(s));
      await _castCurrent();
      castInfo.value = CastInfo(d.name, volume: s.volume);
      _castSync = Timer.periodic(const Duration(seconds: 5), (_) => _castDrift());
    } catch (e) {
      _cast = null;
      _setMainVolume(_mainVolume);
      castInfo.value = null;
      playerNotices.add("Couldn't cast to ${d.name}: ${'$e'.replaceFirst('Exception: ', '')}");
    }
  }

  Future<void> stopCasting() async {
    final s = _cast;
    if (s == null) return;
    await s.close();
  }

  void setCastVolume(double v) {
    _cast?.setVolume(v);
    final i = castInfo.value;
    if (i != null) castInfo.value = CastInfo(i.name, volume: v);
  }

  void _castEnded(CastSession s) {
    if (_cast != s) return;
    _cast = null;
    _castSub?.cancel();
    _castSync?.cancel();
    castInfo.value = null;
    player.pause(); // like Spotify: the music doesn't suddenly come out of the phone
    _setMainVolume(_mainVolume);
    playerNotices.add('Stopped casting to ${s.device.name}');
  }

  /// Send the song that's playing to the speaker.
  Future<void> _castCurrent() async {
    final s = _cast, relay = _relay, c = container.read(clientProvider);
    final song = currentSong;
    if (s == null || relay == null) return;
    final station = radioStation;
    if (station != null) {
      await s.load(station.streamUrl, contentType: 'audio/mpeg', title: station.name, artist: 'Internet radio');
      return;
    }
    if (song == null) return;
    final file = container.read(downloadsProvider).files[song.id];
    final suffix = (file?.split('.').last ?? song.suffix).toLowerCase(); // a download may be a smaller Opus copy
    // m4a over ~600 kbps is Apple Lossless, which speakers can't play: converted like any other format
    final native = castNative[suffix] != null && !(suffix == 'm4a' && (song.bitRate ?? 0) > 600);
    String src, type;
    final serverNative = castNative[song.suffix.toLowerCase()] != null;
    if (file != null && native) {
      (src, type) = (file, castNative[suffix]!);
    } else if (c != null && serverNative) {
      (src, type) = (c.streamUrl(song.id).toString(), castNative[song.suffix.toLowerCase()]!);
    } else if (c != null) {
      (src, type) = (c.streamUrl(song.id, format: 'mp3', maxBitRate: 320).toString(), 'audio/mpeg');
    } else {
      return playerNotices.add("This song can't be cast without your server");
    }
    final art = c != null && song.coverArt.isNotEmpty
        ? relay.artUrl(song.coverArt, c.coverUrl(song.coverArt, size: 600).toString())
        : null;
    _castCommandAt = DateTime.now();
    await s.load(
      relay.songUrl(song.id, src, type),
      contentType: type,
      title: song.title,
      artist: song.artist,
      album: song.album,
      image: art,
      position: player.position,
      play: player.playing,
    );
  }

  void _onCastStatus(CastMediaStatus st) {
    _castState = st.state;
    _castPos = (st.position, DateTime.now());
    // paused or played from the TV remote / Google Home: follow it (not our own commands echoing back)
    if (DateTime.now().difference(_castCommandAt) < const Duration(seconds: 3)) return;
    if (st.state == 'PAUSED' && player.playing) player.pause();
    if (st.state == 'PLAYING' && !player.playing) player.play();
  }

  /// Keep the speaker within a couple of seconds of the phone.
  void _castDrift() {
    final s = _cast, p = _castPos;
    if (s == null || p == null || !player.playing || _castState != 'PLAYING') return;
    final there = p.$1 + DateTime.now().difference(p.$2);
    if ((there - player.position).inMilliseconds.abs() > 2500) {
      _castCommandAt = DateTime.now();
      s.seek(player.position);
    }
  }

  // ── Songs you don't have (music-lookup): got "on trial" as soon as they're played or queued ──
  late final SongFetcher fetcher = SongFetcher(
    ask: (ids) async {
      final c = container.read(clientProvider);
      if (c == null) throw StateError('no server');
      return c.lookupSongs(ids, fetch: true);
    },
  )
    ..onChange = _fetchChanged
    ..onUnreachable = _fetchUnreachable;

  /// Playing or queueing a song you don't have gets it straight away (the setting is on and the server answers).
  bool get autoGet =>
      _settings.autoGetSongs && container.read(clientProvider) != null && !container.read(offlineProvider);

  /// Whether a song can go in the queue: one you don't have only when it's got automatically.
  bool usable(Song s) => (!s.isLookup || autoGet) && canPlay(s);

  final Set<String> _onTrial = {}; // songs that arrived on trial this session (deleted later unless hearted)
  bool isOnTrial(String id) => _onTrial.contains(id);
  void kept(String id) => _onTrial.remove(id);

  String? _waitingFor; // the playing song you don't have, still on its way
  Timer? _waitTimer;
  String? get waitingFor => _waitingFor;

  void _fetchAll() {
    if (!autoGet) return;
    final ids = [for (final s in _songs) if (s.isLookup) s.id];
    if (ids.isNotEmpty) fetcher.want(ids);
  }

  void _fetchChanged(FetchInfo f) {
    if (f.status == FetchStatus.ready && f.songId != null) {
      _arrived(f);
      return;
    }
    _retag(f.id, f.failed ? LookupState.failed : LookupState.downloading);
    final cur = currentSong;
    if (f.failed && cur != null && cur.id == f.id) _giveUp(cur, f);
  }

  void _fetchUnreachable() {
    playerNotices.add("Your server's song finder isn't answering, so songs you don't have can't be got right now");
    final cur = currentSong;
    if (cur != null && cur.id == _waitingFor) _giveUp(cur, null);
  }

  /// Show how getting a song is going on its queue entries (⏳ on its way, ✕ couldn't be had).
  void _retag(String id, LookupState state) {
    var changed = false;
    for (var i = 0; i < _songs.length; i++) {
      if (_songs[i].id == id && _songs[i].lookup != state) {
        _songs[i] = _songs[i].copyWith(lookup: state);
        changed = true;
      }
    }
    if (changed) _broadcastQueue();
  }

  /// A song you didn't have is on your server now: its queue entries become your copy (it plays right away
  /// if it's the one waiting).
  Future<void> _arrived(FetchInfo f, {int tries = 0}) async {
    final c = container.read(clientProvider);
    if (c == null) return;
    Song real;
    try {
      real = await c.song(f.songId!);
    } catch (_) {
      if (tries < 3) Timer(const Duration(seconds: 5), () => _arrived(f, tries: tries + 1));
      return;
    }
    // a heart given while it was on its way stays (the server hearts your copy too)
    final liked = container.read(heartsProvider)[f.id];
    if (liked != null && liked != real.starred) real = real.copyWith(starred: liked);
    if (liked != null) container.read(heartsProvider.notifier).set(real.id, liked);
    if (f.temporary && !real.starred) _onTrial.add(real.id);
    final cur = player.currentIndex;
    var here = false;
    _rearranging = true;
    try {
      for (var i = 0; i < _songs.length; i++) {
        if (_songs[i].id != f.id) continue;
        _songs[i] = real;
        await player.removeAudioSourceAt(i);
        await player.insertAudioSource(i, _source(real));
        if (i == cur) {
          here = true;
          await player.seek(Duration.zero, index: i);
        }
      }
    } catch (_) {
      // the queue changed underneath; the entry plays the server's copy anyway (same address)
    } finally {
      _rearranging = false;
    }
    final o = _original;
    if (o != null) {
      for (var i = 0; i < o.length; i++) {
        if (o[i].id == f.id) o[i] = real;
      }
    }
    if (_autoplay.remove(f.id)) _autoplay.add(real.id);
    if (_suggested.remove(f.id)) _suggested.add(real.id);
    _broadcastQueue();
    _scheduleSave();
    if (here) {
      final waited = _waitingFor == f.id;
      _stopWaiting();
      _onIndex(player.currentIndex); // it's that song for real now (now playing, plays counted, autoplay)
      if (waited) player.play();
    }
  }

  /// The playing song isn't here yet: hold (silence, paused) until it is, for a couple of minutes at most.
  void _waitFor(Song s) {
    final f = fetcher[s.id];
    if (f != null && f.failed) {
      _giveUp(s, f);
      return;
    }
    if (fetcher.unreachable) {
      _giveUp(s, null);
      return;
    }
    _waitingFor = s.id;
    player.pause();
    playerNotices.add('Getting "${s.title}" from your server… it plays as soon as it\'s there');
    _waitTimer?.cancel();
    _waitTimer = Timer(const Duration(minutes: 2), () {
      final cur = currentSong;
      if (_waitingFor == s.id && cur != null && cur.id == s.id) _giveUp(cur, null);
    });
    fetcher.want([s.id]);
  }

  void _stopWaiting() {
    _waitingFor = null;
    _waitTimer?.cancel();
    _waitTimer = null;
  }

  /// A song you don't have can't be had (or not soon): say why, and go on with the next one.
  Future<void> _giveUp(Song s, FetchInfo? f) async {
    _stopWaiting();
    final why = switch (f?.status) {
      FetchStatus.notFound => 'no copy of it was found',
      FetchStatus.limit => "today's ${fetcher.rules?.perDay ?? 40} new songs are used up",
      _ =>
        fetcher.unreachable
            ? "your server's song finder isn't answering"
            : "it's taking a while (it goes in your On trial playlist if it comes)",
    };
    playerNotices.add('Skipped "${s.title}": $why');
    final i = player.currentIndex;
    if (i == null || i >= _songs.length || _songs[i].id != s.id) return;
    final next = _songs.indexWhere((x) => x.id != s.id && !(x.isLookup && (fetcher[x.id]?.failed ?? false)), i + 1);
    if (next < 0) {
      await player.pause();
      return;
    }
    await player.seek(Duration.zero, index: next);
    player.play();
  }

  // ── Sources ──
  /// Downloaded, or the server can be reached (offline, only downloaded songs play).
  bool canPlay(Song s) =>
      container.read(downloadsProvider).files.containsKey(s.id) ||
      (container.read(clientProvider) != null && !container.read(offlineProvider));

  final Set<String> _onPhone = {}; // queue songs whose source is the downloaded file

  AudioSource _source(Song s) {
    final local = container.read(downloadsProvider).files[s.id];
    final item = _mediaItem(s);
    if (local != null) {
      _onPhone.add(s.id);
      return AudioSource.file(local, tag: item);
    }
    _onPhone.remove(s.id);
    final c = container.read(clientProvider);
    if (c == null) return AudioSource.uri(Uri.parse('file:///missing/${s.id}'), tag: item); // fails, then skipped
    // a song you don't have: the server's copy once it's there; meanwhile silence (got automatically) or a preview
    if (s.isLookup) return AudioSource.uri(c.streamUrl(s.id, hold: autoGet), tag: item);
    final set = _settings;
    final wifi = container.read(onWifiProvider);
    final fmt = wifi ? set.wifiFormat : set.mobileFormat;
    final rate = wifi ? set.wifiBitrate : set.mobileBitrate;
    return AudioSource.uri(
      c.streamUrl(s.id, format: fmt, maxBitRate: fmt == 'raw' ? null : rate),
      tag: item,
    );
  }

  /// The lock screen's, notification's and widget's picture: the one kept on the phone when there is one
  /// (shows with no server too), else the server's.
  static Uri? _artUri(SubsonicClient? c, String coverArt) {
    if (c == null || coverArt.isEmpty) return null;
    final kept = savedCovers?.file(c.creds.base, coverArt, SavedCovers.large);
    return kept != null ? Uri.file(kept.path) : c.stableCoverUrl(coverArt);
  }

  /// The same for the car's lists, which can't open Encore's own files: shared through CoverArtProvider.
  static Uri? _carArtUri(SubsonicClient? c, String coverArt) {
    if (c == null || coverArt.isEmpty) return null;
    final kept = savedCovers?.best(c.creds.base, coverArt, 300);
    return kept != null ? sharedCoverUri(kept.$1) : c.coverUrl(coverArt, size: 300);
  }

  MediaItem _mediaItem(Song s) {
    final c = container.read(clientProvider);
    return MediaItem(
      id: s.id,
      title: s.title,
      album: s.album,
      artist: s.artist,
      genre: s.genre,
      duration: s.duration != null ? Duration(seconds: s.duration!) : null,
      artUri: _artUri(c, s.coverArt),
      rating: Rating.newHeartRating(s.starred),
      extras: {'albumId': s.albumId, 'artistId': s.artistId},
    );
  }

  // ── Queue operations (used by the app's menus) ──
  Future<void> playSongs(
    List<Song> songs, {
    int index = 0,
    bool shuffle = false,
    bool allowLookup = false,
    Song? radio,
    PlayContext? context,
    String? source,
  }) async {
    radioSeed = radio;
    radioStation = null;
    _newQueue();
    playContext = context;
    playSource = source ?? context?.key;
    var list = songs.where((s) => (allowLookup || !s.isLookup || autoGet) && canPlay(s)).toList();
    if (list.isEmpty) {
      if (songs.isNotEmpty) {
        playerNotices.add(
          !container.read(offlineProvider)
              ? 'Nothing here can be played'
              : "You're offline and none of these songs are downloaded",
        );
      }
      return;
    }
    if (index >= 0 && index < songs.length) {
      final want = songs[index];
      index = max(0, list.indexWhere((s) => s.id == want.id));
    } else {
      index = 0;
    }
    _suggested.clear();
    _pickPool.clear();
    if (shuffle) {
      _original = list;
      list = [...list]..shuffle();
      index = 0;
      _shuffleKind = radio == null && smartShufflePreferred ? ShuffleKind.smart : ShuffleKind.on;
    } else {
      _original = null;
      _shuffleKind = ShuffleKind.off;
    }
    _songs
      ..clear()
      ..addAll(list);
    await player.setShuffleModeEnabled(false);
    final ok = await _load(list, index.clamp(0, list.length - 1));
    _broadcastQueue();
    _rebroadcast();
    if (ok) player.play();
    _scheduleSave();
    if (_shuffleKind == ShuffleKind.smart) _smartFill();
    _keepGoing(); // a single song: autoplay lines up what comes after it
  }

  /// A new queue replaces the old one: autoplay songs go with it.
  void _newQueue() {
    _queueGen++;
    _queueHistory.clear(); // what you played before isn't what this is about
    _autoplay.clear();
    autoplaySeed = null;
  }

  /// Load a new queue. If the first song can't be loaded (server down, file gone, unreadable file), start
  /// from the next one that loads. False when none would (nothing should then claim to be playing).
  bool _loading = false; // a queue is being loaded (its errors are handled there)

  Future<bool> _load(List<Song> list, int index, {Duration? position, bool quiet = false}) async {
    _loading = true;
    try {
      return await _loadNow(list, index, position: position, quiet: quiet);
    } finally {
      _loading = false;
    }
  }

  Future<bool> _loadNow(List<Song> list, int index, {Duration? position, bool quiet = false}) async {
    final offline = container.read(offlineProvider);
    final files = container.read(downloadsProvider).files;
    for (var i = index, tries = 0; i < list.length && tries < 6; i++) {
      if (offline && !files.containsKey(list[i].id)) continue; // can't stream it: don't even try
      tries++;
      try {
        await player.setAudioSources(
          list.map(_source).toList(),
          initialIndex: i,
          initialPosition: i == index ? position : null,
        );
        if (i != index && !quiet) {
          playerNotices.add("Couldn't play \"${list[index].title}\", skipped it");
          if (!offline) _diagnose(list[index]);
        }
        _loaded = true;
        return true;
      } on PlayerException catch (_) {
        container.read(serverReachableProvider.notifier).suspect();
      } on PlayerInterruptedException catch (_) {
        return false; // replaced by a newer request
      }
    }
    _loaded = false;
    if (!offline && index < list.length) _diagnose(list[index]);
    if (!quiet) {
      playerNotices.add(
        offline ? "Can't reach your server, and none of these songs are downloaded" : "Couldn't play these songs right now",
      );
    }
    return false;
  }

  /// Whether the player holds the queue. A restored queue that couldn't load (server away at start-up)
  /// is loaded again when you press play.
  bool _loaded = false;
  int _restoredIndex = 0;

  Future<void> playNext(List<Song> songs) => insertSongs((player.currentIndex ?? -1) + 1, songs);

  /// Put songs into the queue at [at] (clamped to after the playing song and the end).
  Future<void> insertSongs(int at, List<Song> songs) async {
    final add = songs.where(usable).toList();
    if (add.isEmpty) return;
    if (_songs.isEmpty || radioStation != null) return playSongs(add);
    at = at.clamp((player.currentIndex ?? -1) + 1, _songs.length);
    // you chose it now: autoplay's own copy of it (still to come) goes, so it isn't there twice
    final ids = add.map((s) => s.id).toSet();
    final cur = player.currentIndex ?? -1;
    _rearranging = true;
    try {
      for (var k = _songs.length - 1; k > cur; k--) {
        if (ids.contains(_songs[k].id) && _autoplay.contains(_songs[k].id)) {
          _songs.removeAt(k);
          await player.removeAudioSourceAt(k);
          if (k < at) at--;
        }
      }
    } finally {
      _rearranging = false;
    }
    _autoplay.removeAll(ids);
    _original?.addAll(add);
    _songs.insertAll(at, add);
    await player.insertAudioSources(at, add.map(_source).toList());
    _broadcastQueue();
    _scheduleSave();
  }

  Future<void> addLast(List<Song> songs) async {
    final add = songs.where(usable).toList();
    if (add.isEmpty) return;
    if (_songs.isEmpty) return playSongs(add);
    // what you add goes before autoplay's songs, like Spotify's queue
    final firstAuto = _songs.indexWhere((s) => _autoplay.contains(s.id), (player.currentIndex ?? -1) + 1);
    if (firstAuto >= 0) return insertSongs(firstAuto, add);
    _original?.addAll(add);
    _songs.addAll(add);
    await player.addAudioSources(add.map(_source).toList());
    _broadcastQueue();
    _scheduleSave();
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _songs.length) return;
    final gone = _songs.removeAt(index);
    _suggested.remove(gone.id);
    if (_autoplay.remove(gone.id) && index > (player.currentIndex ?? -1)) _countSkip(gone.id); // not for you
    final o = _original?.indexWhere((s) => s.id == gone.id) ?? -1;
    if (o >= 0) _original!.removeAt(o);
    await player.removeAudioSourceAt(index);
    _broadcastQueue();
    _scheduleSave();
    _keepGoing();
  }

  Future<void> moveQueueItem(int from, int to) async {
    if (from == to || from < 0 || to < 0 || from >= _songs.length || to >= _songs.length) return;
    final s = _songs.removeAt(from);
    _songs.insert(to, s);
    await player.moveAudioSource(from, to);
    _broadcastQueue();
    _scheduleSave();
  }

  Future<void> clearQueue() async {
    _newQueue();
    _songs.clear();
    radioStation = null;
    _resetShuffle();
    await player.stop();
    await player.clearAudioSources();
    mediaItem.add(null);
    _broadcastQueue();
    _scheduleSave();
  }

  /// Replace a song's details everywhere in the queue (after a heart or rating change).
  void updateSong(Song s) {
    for (var i = 0; i < _songs.length; i++) {
      if (_songs[i].id == s.id) _songs[i] = s;
    }
    if (mediaItem.value?.id == s.id) mediaItem.add(_mediaItem(s));
    _broadcastQueue();
  }

  Song? get currentSong {
    final i = player.currentIndex;
    return i != null && i < _songs.length ? _songs[i] : null;
  }

  /// Play an internet radio station (a live stream; the queue is cleared).
  Future<void> playRadio(InternetRadio r, {Uri? art}) async {
    await clearQueue();
    radioStation = r;
    final item = MediaItem(id: 'radio-${r.id}', title: r.name, artist: 'Internet radio', artUri: art);
    try {
      await player.setAudioSource(AudioSource.uri(Uri.parse(r.streamUrl), tag: item));
    } on PlayerException catch (_) {
      radioStation = null;
      playerNotices.add("${r.name} isn't answering right now");
      return;
    } on PlayerInterruptedException catch (_) {
      return;
    } on FormatException catch (_) {
      radioStation = null;
      playerNotices.add("That station's address isn't valid");
      return;
    }
    mediaItem.add(item);
    player.play();
  }

  /// Queue entries that are downloaded but were set up to stream (queued before the download finished, or
  /// restored before the download list was read) switch to the phone's file. The playing one is left alone
  /// unless [includeCurrent] (it just failed).
  Future<void> useDownloadedFiles({bool includeCurrent = false}) async {
    final files = container.read(downloadsProvider).files;
    final cur = player.currentIndex;
    _rearranging = true;
    try {
      for (var i = 0; i < _songs.length; i++) {
        final s = _songs[i];
        if (!files.containsKey(s.id) || _onPhone.contains(s.id) || (i == cur && !includeCurrent)) continue;
        final wasPlaying = i == cur && player.playing;
        await player.removeAudioSourceAt(i);
        await player.insertAudioSource(i, _source(s));
        if (i == cur) await player.seek(Duration.zero, index: i);
        if (wasPlaying) player.play();
      }
    } catch (_) {
      // the queue changed underneath; the next failure tries again
    } finally {
      _rearranging = false;
    }
  }

  /// The way to the server changed (a USB cable plugged in or out): songs queued to stream are set up again
  /// with the new address. The playing one carries on from where it is (unplugged, its old address is gone).
  Future<void> refreshStreams() async {
    final cur = player.currentIndex;
    final pos = player.position;
    _rearranging = true;
    try {
      for (var i = 0; i < _songs.length; i++) {
        final s = _songs[i];
        if (_onPhone.contains(s.id)) continue; // plays from the phone either way
        final wasPlaying = i == cur && player.playing;
        await player.removeAudioSourceAt(i);
        await player.insertAudioSource(i, _source(s));
        if (i == cur) await player.seek(pos, index: i);
        if (wasPlaying) player.play();
      }
    } catch (_) {
      // the queue changed underneath; a song that then fails is skipped as usual
    } finally {
      _rearranging = false;
    }
  }

  /// After a song failed: play it from the phone if it's downloaded, else the next one that can play
  /// (offline, only downloaded songs can).
  Future<void> _skipToPlayable() async {
    final cur = player.currentIndex;
    final files = container.read(downloadsProvider).files;
    if (cur != null && cur < _songs.length && files.containsKey(_songs[cur].id) && !_onPhone.contains(_songs[cur].id)) {
      await useDownloadedFiles(includeCurrent: true);
      player.play();
      return;
    }
    await useDownloadedFiles();
    if (cur != null && cur < _songs.length && !container.read(offlineProvider)) {
      playerNotices.add("Couldn't play \"${_songs[cur].title}\", skipped it");
      _diagnose(_songs[cur]);
    }
    final from = (cur ?? -1) + 1;
    final offline = container.read(offlineProvider);
    for (var i = from; i < _songs.length; i++) {
      if (!offline || files.containsKey(_songs[i].id)) {
        await player.seek(Duration.zero, index: i);
        return;
      }
    }
    await player.pause();
    if (offline) playerNotices.add("Can't reach your server, and nothing else in the queue is downloaded");
  }

  /// The server answers but a song won't play: ask it why, and say so plainly (a banner over the player).
  Future<void> _diagnose(Song s) async {
    if (isPodcastId(s.id) || s.isLookup) return;
    final why = await container.read(clientProvider)?.streamProblem(s.id);
    if (why == null) return;
    final w = why.toLowerCase();
    serverTrouble.value = w.contains('input/output') || w.contains('i/o error')
        ? "Your server can't read its music drive right now (a USB drive may have disconnected). "
              'Downloaded songs still play.'
        : w.contains('no such file') || w.contains('not found')
        ? 'Some songs are missing on your server (moved or deleted). A library rescan may help.'
        : 'Your server had trouble playing a song: $why';
  }

  // ── Podcasts ──
  /// Play an episode (and [then] after it), from where you stopped last time.
  Future<void> playEpisode(PodcastEpisode e, {List<PodcastEpisode> then = const []}) async {
    await playSongs([e.toSong(), ...then.where((x) => x.id != e.id).map((x) => x.toSong())]);
    if (e.inProgress) await player.seek(Duration(milliseconds: e.position));
  }

  Future<void> _savePodcast() async {
    final s = currentSong;
    final c = container.read(clientProvider);
    if (s == null || !isPodcastId(s.id) || c == null || container.read(offlineProvider)) return;
    if (_podActive != s.id) return; // not played here yet: leave the server's position alone
    _podSavedAt = DateTime.now();
    final pos = player.position.inMilliseconds;
    final len = (player.duration ?? Duration(seconds: s.duration ?? 0)).inMilliseconds;
    try {
      if (len > 0 && pos >= len * 0.95) {
        if (_podDone != s.id) {
          _podDone = s.id;
          await c.podcastProgress(s.id, played: true);
          // remembered, so the phone's copy can go after a week (see cleanPlayedEpisodes)
          final done = (jsonDecode(prefs.getString('podcastDone') ?? '{}') as Map).cast<String, dynamic>();
          done[s.id] = DateTime.now().millisecondsSinceEpoch;
          await prefs.setString('podcastDone', jsonEncode(done));
        }
      } else if (pos > 5000) {
        await c.podcastProgress(s.id, positionMs: pos);
      }
    } catch (_) {}
  }

  // ── Mixes ──
  Future<void> instantMix(Song seed) async {
    final c = container.read(clientProvider);
    if (c == null) return;
    final similar = await c.similarSongs(seed.id, count: 50);
    await playSongs([seed, ...similar.where((s) => s.id != seed.id && (!s.isLookup || autoGet))]);
  }

  /// Song radio (like Spotify's): the song, then songs that sound like it; it never runs out.
  Future<bool> songRadio(Song seed) async {
    final c = container.read(clientProvider);
    if (c == null) return false;
    final similar = (await c.similarSongs(seed.id, count: 60)).where((s) => s.id != seed.id && (!s.isLookup || autoGet)).toList();
    if (similar.isEmpty) return false;
    similar.shuffle();
    await playSongs([seed, ...similar.take(40)], radio: seed);
    return true;
  }

  // ── Keeping the music going: song radio and autoplay ──
  /// Runs whenever the song or the queue changes. A song radio keeps growing with songs like its song;
  /// otherwise, when what you chose is about to run out, autoplay lines up a few songs like the last ones.
  Future<void> _keepGoing() async {
    final i = player.currentIndex;
    if (_autoFilling || i == null || i >= _songs.length || radioStation != null) return;
    if (player.loopMode != LoopMode.off) return; // repeating: the queue never runs out
    if (isPodcastId(_songs[i].id)) return;
    final radio = radioSeed;
    final ahead = _songs.length - 1 - i;
    if (radio != null) {
      if (ahead > 2) return;
    } else {
      if (!_settings.autoplay) return;
      final chosenAhead = _songs.skip(i + 1).where((s) => !_autoplay.contains(s.id)).length;
      if (chosenAhead > 1 || ahead - chosenAhead >= 3) return; // still yours to play, or enough lined up
    }
    final gen = _queueGen;
    _autoFilling = true;
    try {
      final picks = await _nextPicks(radio != null ? 15 : 5, radio: radio);
      // something else started playing meanwhile: these were for the old queue
      if (picks.isEmpty || gen != _queueGen || radioSeed != radio || _songs.isEmpty) return;
      if (radio == null && !_settings.autoplay) return;
      final have = _songs.map((s) => s.id).toSet();
      final add = picks.where((s) => have.add(s.id)).toList();
      if (add.isEmpty) return;
      _autoUsed.addAll(add.map((s) => s.id));
      if (radio == null) {
        _autoplay.addAll(add.map((s) => s.id));
      } else {
        _original?.addAll(add); // a radio's songs are the radio itself
      }
      final ended = player.processingState == ProcessingState.completed && player.currentIndex == _songs.length - 1;
      final next = _songs.length;
      _songs.addAll(add);
      await player.addAudioSources(add.map(_source).toList());
      _broadcastQueue();
      _scheduleSave();
      if (ended && !_extras.sleepAfterTrack) {
        // the last song finished before these were ready: carry on with them
        await player.seek(Duration.zero, index: next);
        player.play();
      }
    } catch (_) {
      // a failed fetch: tried again when the song changes, or when the queue ends
    } finally {
      _autoFilling = false;
      if (gen != _queueGen) _keepGoing(); // a new queue came while fetching for the old one
    }
  }

  /// The queue ran out anyway (the songs weren't ready in time): fetch them now; they start when they come.
  void _continueAfterEnd() {
    if (player.currentIndex == _songs.length - 1) _keepGoing();
  }

  /// Take autoplay's songs that haven't played yet out of the queue (switched off, or shuffle changed).
  Future<void> _dropAutoplay() async {
    final cur = player.currentIndex ?? -1;
    if (!_songs.skip(cur + 1).any((s) => _autoplay.contains(s.id))) return;
    _rearranging = true;
    try {
      for (var k = _songs.length - 1; k > cur; k--) {
        if (_autoplay.remove(_songs[k].id)) {
          _songs.removeAt(k);
          await player.removeAudioSourceAt(k);
        }
      }
    } finally {
      _rearranging = false;
    }
    _onIndex(player.currentIndex);
    _broadcastQueue();
    _scheduleSave();
  }

  /// The next songs for autoplay (or a song radio): seeded from the last few songs played, mixed from
  /// sound-alikes, similar artists, the genre, your favourites and frequent plays, and a little discovery.
  /// Offline (or when the server isn't answering), only downloaded songs.
  Future<List<Song>> _nextPicks(int n, {Song? radio}) async {
    final c = container.read(clientProvider);
    final i = min(player.currentIndex ?? 0, _songs.length - 1);
    final played = [..._history];
    if (played.isEmpty || played.last.id != _songs[i].id) played.add(_songs[i]);
    // seeds from this queue only (a song from search follows that song, not what played before it); a queue
    // restored at start-up has no history yet, so the songs up to the playing one stand in
    final mine = _queueHistory.isNotEmpty ? [..._queueHistory] : _songs.take(i + 1).toList();
    if (mine.isEmpty || mine.last.id != _songs[i].id) mine.add(_songs[i]);
    var seeds = chooseSeeds(mine);
    if (radio != null) seeds = [radio, ...seeds.where((s) => s.id != radio.id).take(1)];
    final recent = [...played, ..._songs.skip(i + 1)];
    final exclude = {..._songs.map((s) => s.id), ..._recentIds, ..._autoUsed};
    final genres = {for (final s in seeds) if (s.genre.isNotEmpty) s.genre};
    final weights = radio != null ? radioWeights : autoplayWeights;

    // [loose]: a small library (or few downloads) may have nothing left that wasn't played lately; then only
    // the queue and the last few songs are off limits
    List<Song> pick((List<AutoCandidate>, Set<String>) from, {bool loose = false}) => pickAutoplay(
      candidates: from.$1.where((x) => canPlay(x.song)).toList(),
      allowLookup: autoGet,
      n: n,
      recent: recent,
      exclude: loose ? {..._songs.map((s) => s.id), ..._history.map((s) => s.id)} : exclude,
      excludeKeys: loose ? const {} : {..._recentKeys},
      skips: _skips,
      seedGenres: genres,
      relatedArtists: from.$2,
      weights: weights,
    ).map((x) => x.song).toList();

    // most fitting first; loosening "not played lately" only when nothing new is left anywhere
    final sets = <(List<AutoCandidate>, Set<String>)>[];
    var picks = const <Song>[];
    if (c != null && !container.read(offlineProvider)) {
      // includes some of anything from your library: when nothing like it is new any more, those come
      sets.add(await _onlineCandidates(c, seeds));
      picks = pick(sets.last);
    }
    if (picks.isEmpty) {
      sets.add(await _offlineCandidates(seeds));
      picks = pick(sets.last);
    }
    for (final set in sets) {
      if (picks.isNotEmpty) break;
      picks = pick(set, loose: true);
    }
    if (picks.isNotEmpty && radio == null && seeds.isNotEmpty) autoplaySeed = seeds.first;
    return picks;
  }

  static Future<T> _safe<T>(Future<T> f, T empty) async {
    try {
      return await f.timeout(const Duration(seconds: 20));
    } catch (_) {
      return empty;
    }
  }

  Future<(List<AutoCandidate>, Set<String>)> _onlineCandidates(SubsonicClient c, List<Song> seeds) async {
    final main = seeds.firstOrNull;
    final related = {for (final s in seeds) artistKey(s)};
    final similar = Future.wait([for (final s in seeds) _safe(c.similarSongs(s.id, count: 25), const <Song>[])]);
    final info = main == null || main.artistId.isEmpty
        ? Future.value(const ArtistInfo())
        : _safe(c.artistInfo(main.artistId), const ArtistInfo());
    final genre = main == null || main.genre.isEmpty
        ? Future.value(const <Song>[])
        : _safe(c.randomSongs(size: 40, genre: main.genre), const <Song>[]);
    final favs = _favourites(), freq = _frequent(c);
    final any = _safe(c.randomSongs(size: 40), const <Song>[]);

    final out = <AutoCandidate>[];
    for (final l in await similar) {
      for (final (k, s) in l.indexed) {
        out.add(AutoCandidate(s, AutoSource.soundAlike, k));
      }
    }
    // similar artists (Last.fm through the server; AudioMuse when that has nothing), a few of their songs
    var artists = (await info).similar.where((a) => a.name.isNotEmpty).toList();
    if (artists.isEmpty && main != null) {
      artists = await _safe(container.read(aiProvider)?.similarArtists(main.artist) ?? Future.value(const <Artist>[]),
          const <Artist>[]);
    }
    related.addAll(artists.map((a) => artistKey(Song(id: '', title: '', artist: a.name))));
    final some = (artists.take(8).toList()..shuffle()).take(3).toList();
    final theirs = await Future.wait([for (final a in some) _artistSongs(c, a)]);
    for (final l in theirs) {
      for (final (k, s) in l.indexed) {
        out.add(AutoCandidate(s, AutoSource.similarArtist, k));
      }
    }
    for (final (k, s) in (await genre).indexed) {
      // songs you've played before fit; never-played ones are the discovery part
      out.add(AutoCandidate(s, (s.playCount ?? 0) > 0 ? AutoSource.genre : AutoSource.discovery, k));
    }
    for (final (k, s) in (await favs).indexed) {
      out.add(AutoCandidate(s, AutoSource.favourite, k));
    }
    for (final (k, s) in (await freq).indexed) {
      out.add(AutoCandidate(s, AutoSource.frequent, k));
    }
    for (final (k, s) in (await any).indexed) {
      out.add(AutoCandidate(s, AutoSource.anything, k));
    }
    return (out, related);
  }

  /// A few songs by an artist: their top songs, else one of their albums.
  Future<List<Song>> _artistSongs(SubsonicClient c, Artist a) async {
    final top = await _safe(c.topSongs(a.name, count: 10), const <Song>[]);
    if (top.isNotEmpty || a.id.isEmpty) return top;
    final repo = container.read(repoProvider);
    final full = await _safe(repo.artist(a.id), null as Artist?);
    final albums = [...?full?.albums.where((x) => !x.isLookup)]..shuffle();
    if (albums.isEmpty) return const [];
    final album = await _safe(repo.album(albums.first.id), null as Album?);
    return [...?album?.songs]..shuffle();
  }

  Future<List<Song>> _favourites() async {
    final c = _favCache;
    if (c != null && DateTime.now().difference(c.$1) < const Duration(minutes: 15)) return c.$2;
    final songs = (await _safe(container.read(repoProvider).starred(), null as SearchResult?))?.songs ?? const <Song>[];
    final mixed = [...songs]..shuffle();
    _favCache = (DateTime.now(), mixed);
    return mixed;
  }

  /// What you've played most this month (this year when the month is quiet), from your listening stats.
  Future<List<Song>> _frequent(SubsonicClient c) async {
    final cached = _freqCache;
    if (cached != null && DateTime.now().difference(cached.$1) < const Duration(hours: 1)) return cached.$2;
    var songs = <Song>[];
    for (final period in ['month', 'year']) {
      final st = await _safe(c.listeningStats(period), null as ListeningStats?);
      songs = [for (final (s, _) in st?.songs ?? const <(Song, int)>[]) if (!s.isLookup) s];
      if (songs.length >= 10) break;
    }
    _freqCache = (DateTime.now(), songs);
    return songs;
  }

  /// From downloaded songs only: same artists and genre first, then favourites, most played and the rest.
  Future<(List<AutoCandidate>, Set<String>)> _offlineCandidates(List<Song> seeds) async {
    final files = container.read(downloadsProvider).files;
    final all = [
      for (final (s, _, _) in await _safe(container.read(dbProvider).downloads(), const <(Song, String, int)>[]))
        if (files.containsKey(s.id) && !isPodcastId(s.id)) s,
    ]..shuffle();
    final artists = {for (final s in seeds) artistKey(s)};
    final genres = {for (final s in seeds) if (s.genre.isNotEmpty) s.genre.toLowerCase()};
    final frequent = [...all.where((s) => (s.playCount ?? 0) > 0)]
      ..sort((a, b) => (b.playCount ?? 0).compareTo(a.playCount ?? 0));
    final out = <AutoCandidate>[];
    for (final (k, s) in all.indexed) {
      final source = artists.contains(artistKey(s))
          ? AutoSource.similarArtist
          : genres.contains(s.genre.toLowerCase())
          ? AutoSource.genre
          : s.starred
          ? AutoSource.favourite
          : AutoSource.anything;
      out.add(AutoCandidate(s, source, k));
    }
    for (final (k, s) in frequent.take(50).indexed) {
      out.add(AutoCandidate(s, AutoSource.frequent, k));
    }
    return (out, artists);
  }

  // ── Listening history and skips (for autoplay's choices) ──
  List<String>? _recentIdsCache;
  List<String> get _recentIds => _recentIdsCache ??= prefs.getStringList('recentPlayed') ?? [];
  List<String>? _recentKeysCache;
  List<String> get _recentKeys => _recentKeysCache ??= prefs.getStringList('recentPlayedKeys') ?? [];

  void _played(Song s) {
    _history.add(s);
    if (_history.length > 30) _history.removeAt(0);
    _queueHistory.add(s);
    if (_queueHistory.length > 30) _queueHistory.removeAt(0);
    if (isPodcastId(s.id) || _private) return; // private: autoplay doesn't remember it
    final ids = _recentIds
      ..remove(s.id)
      ..add(s.id);
    if (ids.length > 300) ids.removeRange(0, ids.length - 300);
    prefs.setStringList('recentPlayed', ids);
    final key = songKey(s);
    final keys = _recentKeys
      ..remove(key)
      ..add(key);
    if (keys.length > 300) keys.removeRange(0, keys.length - 300);
    prefs.setStringList('recentPlayedKeys', keys);
  }

  void _countSkip(String id) {
    if (_private) return;
    _skips.skipped(id);
    prefs.setString('skipStats', jsonEncode(_skips.toJson()));
  }

  void _countPlay(String id) {
    if (_private) return;
    _skips.played(id);
    prefs.setString('skipStats', jsonEncode(_skips.toJson()));
  }

  // ── Shuffle and smart shuffle ──
  /// What the shuffle buttons on album / playlist pages start: the last kind picked in the player.
  bool get smartShufflePreferred => prefs.getBool('smartShuffle') ?? false;

  void _resetShuffle() {
    _shuffleKind = ShuffleKind.off;
    _original = null;
    _suggested.clear();
    _pickPool.clear();
    playContext = null;
    playSource = null;
    _rebroadcast();
  }

  void _rebroadcast() => _broadcast(player.playbackEvent);

  /// Switch between off, shuffle and smart shuffle without interrupting the song that's playing.
  Future<void> setShuffleKind(ShuffleKind k) async {
    if (k != ShuffleKind.off) prefs.setBool('smartShuffle', k == ShuffleKind.smart);
    final i = player.currentIndex;
    if (k == _shuffleKind || _songs.isEmpty || i == null || i >= _songs.length) {
      _shuffleKind = k;
      _rebroadcast();
      return;
    }
    await _dropAutoplay(); // autoplay's songs follow the new order; they're lined up again after it
    if (i >= _songs.length) return;
    final cur = _songs[i];
    if (k == ShuffleKind.off) {
      // back to the original order, continuing from the song that's playing; picks leave the queue
      final orig = _original ?? _songs.where((s) => !_suggested.contains(s.id)).toList();
      final at = orig.indexWhere((s) => s.id == cur.id);
      _suggested.removeWhere((id) => id != cur.id);
      _original = null;
      _pickPool.clear();
      _shuffleKind = k;
      await _replaceAround(i, at >= 0 ? orig.sublist(0, at) : const [], at >= 0 ? orig.sublist(at + 1) : orig);
    } else if (_shuffleKind == ShuffleKind.off) {
      // a fresh shuffle of everything except the song that's playing
      _original = [..._songs];
      final rest = [..._songs]..removeAt(i);
      rest.shuffle();
      _shuffleKind = k;
      await _replaceAround(i, const [], rest);
    } else if (k == ShuffleKind.on) {
      _shuffleKind = k;
      await _removePicks();
    } else {
      _shuffleKind = k; // shuffle → smart: same order, picks get added
    }
    _rebroadcast();
    if (k == ShuffleKind.smart) {
      _smartNoticeShown = false;
      _smartFill();
    }
    _keepGoing();
  }

  /// Replace everything around the playing song (index [i]) with [before] and [after]; it keeps playing.
  Future<void> _replaceAround(int i, List<Song> before, List<Song> after) async {
    final cur = _songs[i];
    _rearranging = true;
    try {
      if (i + 1 < _songs.length) await player.removeAudioSourceRange(i + 1, _songs.length);
      if (i > 0) await player.removeAudioSourceRange(0, i);
      if (before.isNotEmpty) await player.insertAudioSources(0, before.map(_source).toList());
      if (after.isNotEmpty) await player.addAudioSources(after.map(_source).toList());
      _songs
        ..clear()
        ..addAll(before)
        ..add(cur)
        ..addAll(after);
      _lastSongId = cur.id;
    } finally {
      _rearranging = false;
    }
    _onIndex(player.currentIndex); // the song may have ended while the queue was rebuilt
    _broadcastQueue();
    _rebroadcast();
    _scheduleSave();
  }

  /// Take smart-shuffle picks out of the queue (but not the one playing).
  Future<void> _removePicks() async {
    final cur = player.currentIndex ?? -1;
    _rearranging = true;
    try {
      for (var k = _songs.length - 1; k >= 0; k--) {
        if (k != cur && _suggested.contains(_songs[k].id)) {
          _songs.removeAt(k);
          await player.removeAudioSourceAt(k);
        }
      }
    } finally {
      _rearranging = false;
    }
    _onIndex(player.currentIndex);
    final now = player.currentIndex;
    _suggested.removeWhere((id) => now == null || now >= _songs.length || _songs[now].id != id);
    _pickPool.clear();
    if (now != null && now < _songs.length) {
      _lastSongId = _songs[now].id;
    }
    _broadcastQueue();
    _scheduleSave();
  }

  /// Keeps smart-shuffle picks lined up ahead: one after every three songs of the list.
  Future<void> _smartFill() async {
    if (_shuffleKind != ShuffleKind.smart || _filling || _songs.isEmpty) return;
    final c = container.read(clientProvider);
    if (c == null || container.read(offlineProvider)) {
      if (!_smartNoticeShown) {
        _smartNoticeShown = true;
        playerNotices.add("Smart shuffle needs the server, so this is a normal shuffle for now");
      }
      return;
    }
    (int, int) where() {
      final i = min(player.currentIndex ?? 0, _songs.length - 1);
      var last = i;
      for (var k = _songs.length - 1; k > i; k--) {
        if (_suggested.contains(_songs[k].id)) {
          last = k;
          break;
        }
      }
      return (i, last);
    }

    var (i, last) = where();
    bool plain(Song s) => !_suggested.contains(s.id) && !_autoplay.contains(s.id);
    final plainAfter = _songs.skip(last + 1).where(plain).length;
    if (plainAfter < 3 || last - i > 12) return;
    _filling = true;
    try {
      final picks = await _smartPicks(6);
      if (_shuffleKind != ShuffleKind.smart || picks.isEmpty) return;
      (i, last) = where(); // the queue may have moved on while fetching
      var pos = last + 1;
      {
        for (final p in picks) {
          var plainCount = 0;
          while (pos < _songs.length && plainCount < 3) {
            if (plain(_songs[pos])) plainCount++;
            pos++;
          }
          if (plainCount < 3) {
            _pickPool.insert(0, p); // no room yet; use it later
            continue;
          }
          _songs.insert(pos, p);
          _suggested.add(p.id);
          _usedPicks.add(p.id);
          await player.insertAudioSource(pos, _source(p));
          pos++;
        }
      }
      _broadcastQueue();
      _scheduleSave();
    } catch (_) {
      // a failed fetch just means no picks this time
    } finally {
      _filling = false;
    }
  }

  /// Songs that sound like the list: sound-alikes of a few random songs from it, mixed, one per artist.
  Future<List<Song>> _smartPicks(int n) async {
    final c = container.read(clientProvider);
    final base = (_original ?? _songs)
        .where((s) => !_suggested.contains(s.id) && !_autoplay.contains(s.id) && !s.isLookup)
        .toList();
    if (c == null || base.isEmpty) return const [];
    final inQueue = _songs.map((s) => s.id).toSet();
    final hidden = _hiddenPicks(playContext?.key ?? '');
    bool ok(Song s) =>
        !s.isLookup && !inQueue.contains(s.id) && !_usedPicks.contains(s.id) && !hidden.contains(s.id) && canPlay(s);
    _pickPool.removeWhere((s) => !ok(s));
    if (_pickPool.length < n) {
      final seeds = ([...base]..shuffle()).take(4).toList();
      final lists = await Future.wait(
        seeds.map((s) => c.similarSongs(s.id, count: 20).catchError((_) => const <Song>[])),
      );
      final seen = {for (final s in _pickPool) s.id};
      for (var r = 0; r < 20; r++) {
        for (final l in lists) {
          if (r < l.length && ok(l[r]) && seen.add(l[r].id)) _pickPool.add(l[r]);
        }
      }
    }
    final out = <Song>[];
    final artists = <String>{};
    for (final s in [..._pickPool]) {
      if (out.length >= n) break;
      if (artists.add(s.artist.toLowerCase())) {
        out.add(s);
        _pickPool.remove(s);
      }
    }
    return out;
  }

  Set<String> _hiddenPicks(String key) {
    try {
      final m = jsonDecode(prefs.getString('smartShuffleHidden') ?? '{}') as Map<String, dynamic>;
      return {...((m[key] as List?) ?? const []).map((e) => '$e')};
    } catch (_) {
      return {};
    }
  }

  /// Keep a smart-shuffle pick: it becomes part of the list. Saved into the playlist (or liked songs) it came
  /// from; returns what happened, or null when the app should ask which playlist.
  Future<String?> keepSuggestion(Song s) async {
    final ctx = playContext;
    final c = container.read(clientProvider);
    String? done;
    if (c != null && ctx?.kind == 'playlist') {
      await c.updatePlaylist(ctx!.id, add: [s.id]);
      done = 'Added to ${ctx.name}';
    } else if (c != null && ctx?.kind == 'starred') {
      await c.star(id: s.id);
      updateSong(s.copyWith(starred: true));
      done = 'Added to Liked songs';
    }
    markKept(s);
    return done;
  }

  /// The pick is part of the list now (no sparkle; it stays when shuffle is switched off).
  void markKept(Song s) {
    if (_suggested.remove(s.id)) _original?.add(s);
    _broadcastQueue();
    _scheduleSave();
  }

  /// Drop a pick: it leaves the queue and isn't suggested for this list again.
  Future<void> dropSuggestion(Song s) async {
    final key = playContext?.key ?? '';
    try {
      final m = jsonDecode(prefs.getString('smartShuffleHidden') ?? '{}') as Map<String, dynamic>;
      final l = [...((m[key] as List?) ?? const []).map((e) => '$e'), s.id];
      m[key] = l.length > 500 ? l.sublist(l.length - 500) : l;
      if (m.length > 200) m.remove(m.keys.first);
      prefs.setString('smartShuffleHidden', jsonEncode(m));
    } catch (_) {}
    final idx = _songs.indexWhere((x) => x.id == s.id);
    if (idx < 0) return;
    if (idx == player.currentIndex && player.hasNext) await player.seekToNext();
    await removeQueueItemAt(idx);
    _smartFill();
  }

  // ── Track change: metadata, ReplayGain, scrobbling, radio ──
  /// Runs when the playing song changes. (The player repeats the same index with every playback event,
  /// so only a real change counts.)
  void _onIndex(int? i) {
    if (_rearranging || i == null || i >= _songs.length) return;
    final s = _songs[i];
    if (s.id == _lastSongId) return; // same song, maybe moved by a queue edit: not a new track
    _lastSongId = s.id;
    if (s.isLookup && autoGet) {
      _waitFor(s); // not here yet: wait for it (or skip it if it can't be had)
    } else if (_waitingFor != null) {
      _stopWaiting();
    }
    final was = _nowSong, sameQueue = _nowGen == _queueGen;
    _nowSong = s;
    _nowGen = _queueGen;
    final moved = _userMoveAt != null && DateTime.now().difference(_userMoveAt!) < const Duration(seconds: 3);
    final forward = moved && _movedForward;
    _userMoveAt = null;
    final early = was != null && _listened < Duration(seconds: min(30, (was.duration ?? 240) * 2 ~/ 5));
    if (was != null && sameQueue && forward && early && !isPodcastId(was.id)) {
      _countSkip(was.id); // skipped early: autoplay brings it less often
    }
    _played(s);
    // the song before ended by itself (not a skip, not a new queue)
    final ended = was != null && sameQueue && !moved && i > 0 && _songs[i - 1].id == was.id;
    if (ended && _extras.sleepAfterTrack) {
      // "sleep after this song": the queue goes on (autoplay), so stop at the start of the next one
      player.pause();
      player.seek(Duration.zero);
      _setExtras(PlayerExtras(speed: _extras.speed));
    }
    if (_fadeFrom != null) {
      _fadeFrom == i - 1 && _fadeTimer != null ? _handOff() : _cancelFade();
    }
    mediaItem.add(_mediaItem(s));
    _applyReplayGain();
    if (_cast != null) _castCurrent();
    _listened = Duration.zero;
    _lastTick = null;
    _submitted = null;
    if (_settings.scrobble && !_private && _scrobbledNow != s.id && !isPodcastId(s.id) && !container.read(offlineProvider)) {
      _scrobbledNow = s.id;
      container.read(clientProvider)?.scrobble(s.id, submission: false).catchError((_) {});
    }
    _keepGoing();
    _smartFill();
    _scheduleSave();
    _reportSoon();
    _fetchMixInfo(i);
  }

  // ── Playback reports (exact play / pause / position for other apps, e.g. the Discord status) ──
  void _reportSoon() {
    _reportTimer?.cancel();
    _reportTimer = Timer(const Duration(milliseconds: 600), _report);
  }

  Future<void> _report() async {
    if (!_reportsWork || !_settings.scrobble) return;
    final c = container.read(clientProvider);
    if (c == null || container.read(offlineProvider)) return;
    if (_private) {
      // say "stopped" once for what was showing, then nothing until the private session ends
      final was = _reportedId;
      if (was == null || _reportedState == 'stopped') return;
      try {
        await c.reportPlayback(was, state: 'stopped', positionMs: 0);
        _reportedId = null;
        _reportedState = 'stopped';
      } catch (_) {}
      return;
    }
    final s = radioStation == null ? currentSong : null;
    final ps = player.processingState;
    final ended = s == null || ps == ProcessingState.completed || ps == ProcessingState.idle;
    final id = s?.id ?? _reportedId;
    if (id == null || (s != null && (s.isLookup || isPodcastId(s.id)))) return;
    final state = ended
        ? 'stopped'
        : !player.playing
        ? 'paused'
        : (_reportedId != id ? 'starting' : 'playing');
    if (state == 'stopped' && _reportedState == 'stopped') return;
    try {
      await c.reportPlayback(id, state: state, positionMs: player.position.inMilliseconds, rate: player.speed);
      if (state == 'starting' && player.playing) {
        await c.reportPlayback(id, state: 'playing', positionMs: player.position.inMilliseconds, rate: player.speed);
      }
      _reportedId = ended ? null : id;
      _reportedState = state;
    } on SubsonicException catch (e) {
      // an older server without playback reports: stop trying (not for passing errors like a 502)
      if (e.code == 70 || e.message.contains(' 404')) _reportsWork = false;
    } catch (_) {}
  }

  /// Counts real listening time (not seeking) and submits the play after half the song or 4 minutes.
  void _onPosition(Duration pos) {
    _fadeTick(pos);
    final now = DateTime.now();
    if (player.playing && _lastTick != null) {
      final d = now.difference(_lastTick!);
      if (d < const Duration(seconds: 2)) _listened += d;
    }
    _lastTick = now;
    final s = currentSong;
    if (s != null && isPodcastId(s.id)) {
      // podcasts: keep where you are on the server (every 15 s), and mark the episode played near its end
      if (player.playing) _podActive = s.id;
      if (player.playing && (_podSavedAt == null || now.difference(_podSavedAt!) > const Duration(seconds: 15))) {
        _savePodcast();
      }
      return;
    }
    if (s == null) return;
    final len = Duration(seconds: s.duration ?? 240);
    final need = Duration(milliseconds: min(len.inMilliseconds ~/ 2, 240000));
    if (_playCounted != s.id && _listened >= need) {
      _playCounted = s.id;
      _countPlay(s.id); // played through: not a song you skip
    }
    if (_submitted == s.id || !_settings.scrobble || _private) return; // private: not even queued for later
    if (_listened >= need) {
      _submitted = s.id;
      final c = container.read(clientProvider);
      if (c != null && !container.read(offlineProvider)) {
        c.scrobble(s.id, submission: true, time: now).catchError((_) {});
      } else {
        _queueOfflineScrobble(s.id, now);
      }
    }
  }

  void _queueOfflineScrobble(String id, DateTime at) {
    final list = prefs.getStringList('pendingScrobbles') ?? [];
    list.add('$id|${at.millisecondsSinceEpoch}');
    prefs.setStringList('pendingScrobbles', list);
  }

  /// Plays that happened offline are sent when the server is reachable again.
  Future<void> flushOfflineScrobbles() async {
    final list = prefs.getStringList('pendingScrobbles') ?? [];
    final c = container.read(clientProvider);
    if (list.isEmpty || c == null) return;
    final left = <String>[];
    for (final e in list) {
      final p = e.split('|');
      final ms = p.length == 2 ? int.tryParse(p[1]) : null;
      if (ms == null) continue; // a broken entry: drop it
      try {
        await c.scrobble(p[0], submission: true, time: DateTime.fromMillisecondsSinceEpoch(ms));
      } catch (_) {
        left.add(e);
      }
    }
    prefs.setStringList('pendingScrobbles', left);
  }

  // ── Saving / restoring the queue ──
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 5), _saveQueue);
  }

  /// Remember the queue and position now (before quitting).
  Future<void> saveNow() => _saveQueue();

  Future<void> _saveQueue() async {
    final i = player.currentIndex ?? 0;
    final pos = player.position.inMilliseconds;
    prefs.setString(
      'queue',
      jsonEncode({
        'songs': _songs.map((s) => s.toJson()).toList(),
        'index': i,
        'position': pos,
        'shuffle': _shuffleKind.name,
        if (_original != null) 'original': _original!.map((s) => s.id).toList(),
        'suggested': _suggested.toList(),
        'autoplay': _autoplay.toList(),
        if (playContext != null) 'context': playContext!.toJson(),
        if (playSource != null) 'source': playSource,
      }),
    );
    final c = container.read(clientProvider);
    if (_settings.syncPlayQueue && c != null && !container.read(offlineProvider) && _songs.length <= 1000) {
      try {
        await c.savePlayQueue(
          _songs.map((s) => s.id).toList(),
          current: _songs.isNotEmpty ? _songs[min(i, _songs.length - 1)].id : null,
          positionMs: pos,
        );
      } catch (_) {}
    }
  }

  /// Switching servers: keep this server's queue where it is (it comes back when you switch back) and stop.
  Future<void> leaveServer() async {
    fetcher.reset();
    _stopWaiting();
    _onTrial.clear();
    _saveTimer?.cancel();
    _cancelFade();
    await _saveQueue();
    _newQueue();
    _songs.clear();
    radioStation = null;
    _resetShuffle();
    await player.stop();
    await player.clearAudioSources();
    mediaItem.add(null);
    _broadcastQueue();
    _loaded = false;
    _lastSongId = null;
  }

  /// After switching servers: that server's queue, as you left it.
  Future<void> enterServer() => _restoreQueue();

  Future<void> _restoreQueue() async {
    final raw = prefs.getString('queue');
    if (raw == null || container.read(clientProvider) == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final songs = (j['songs'] as List).map((e) => Song.fromJson((e as Map).cast<String, dynamic>())).toList();
      if (songs.isEmpty) return;
      final index = ((j['index'] as num?)?.toInt() ?? 0).clamp(0, songs.length - 1);
      _restoredIndex = index;
      _songs.addAll(songs);
      final byId = {for (final s in songs) s.id: s};
      _shuffleKind = ShuffleKind.values.firstWhere((k) => k.name == j['shuffle'], orElse: () => ShuffleKind.off);
      final orig = j['original'];
      if (_shuffleKind != ShuffleKind.off && orig is List) {
        _original = [for (final id in orig) ?byId['$id']];
      }
      _suggested.addAll(((j['suggested'] as List?) ?? const []).map((e) => '$e').where(byId.containsKey));
      _autoplay.addAll(((j['autoplay'] as List?) ?? const []).map((e) => '$e').where(byId.containsKey));
      playContext = PlayContext.fromJson(j['context']);
      playSource = j['source'] as String? ?? playContext?.key;
      await _load(songs, index, position: Duration(milliseconds: (j['position'] as num?)?.toInt() ?? 0), quiet: true);
      _broadcastQueue();
      _rebroadcast();
    } catch (_) {
      _songs.clear();
    }
  }

  /// Take over the queue saved on the server (from Feishin or another device).
  Future<bool> loadServerQueue() async {
    final c = container.read(clientProvider);
    if (c == null) return false;
    final (songs, current, pos) = await c.playQueue();
    if (songs.isEmpty) return false;
    final idx = max(0, songs.indexWhere((s) => s.id == current));
    radioSeed = null;
    _newQueue();
    _resetShuffle();
    _songs
      ..clear()
      ..addAll(songs);
    await _load(songs, idx, position: Duration(milliseconds: pos));
    _broadcastQueue();
    return true;
  }

  // ── Sleep timer ──
  void setSleepTimer(Duration? d, {bool afterTrack = false}) {
    _sleepTimer?.cancel();
    if (d != null) _sleepTimer = Timer(d, _sleepNow);
    _setExtras(
      PlayerExtras(
        sleepAt: d != null ? DateTime.now().add(d) : null,
        sleepAfterTrack: afterTrack,
        speed: _extras.speed,
      ),
    );
  }

  void _sleepNow() {
    _sleepTimer?.cancel();
    pause();
    _setExtras(PlayerExtras(speed: _extras.speed));
  }

  void _setExtras(PlayerExtras e) {
    _extras = e;
    extras.add(e);
  }

  // ── Standard controls ──
  @override
  Future<void> play() async {
    if (!_loaded && _songs.isNotEmpty && radioStation == null) {
      final i = player.currentIndex ?? _restoredIndex;
      if (!await _load(List.of(_songs), i.clamp(0, _songs.length - 1), position: player.position)) return;
    }
    await player.play();
  }
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> stop() async {
    await _saveQueue();
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_fadeFrom != null) _cancelFade();
    await player.seek(position);
    _cast?.seek(position);
    _reportSoon();
  }

  @override
  Future<void> skipToNext() {
    _userMoved(true);
    return player.seekToNext();
  }

  void _userMoved(bool forward) {
    _userMoveAt = DateTime.now();
    _movedForward = forward;
  }
  @override
  Future<void> skipToPrevious() async {
    if (player.position > const Duration(seconds: 4)) return player.seek(Duration.zero);
    _userMoved(false);
    return player.seekToPrevious();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _songs.length) return;
    _userMoved(index > (player.currentIndex ?? 0));
    await player.seek(Duration.zero, index: index);
    player.play();
  }

  @override
  Future<void> setSpeed(double speed) async {
    await player.setSpeed(speed);
    _setExtras(PlayerExtras(sleepAt: _extras.sleepAt, sleepAfterTrack: _extras.sleepAfterTrack, speed: speed));
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) => setShuffleKind(switch (shuffleMode) {
    AudioServiceShuffleMode.none => ShuffleKind.off,
    AudioServiceShuffleMode.group => ShuffleKind.smart,
    AudioServiceShuffleMode.all => ShuffleKind.on,
  });

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await player.setLoopMode(switch (repeatMode) {
      AudioServiceRepeatMode.one => LoopMode.one,
      AudioServiceRepeatMode.all || AudioServiceRepeatMode.group => LoopMode.all,
      _ => LoopMode.off,
    });
    _keepGoing(); // repeat off: the queue can run out again
  }

  @override
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) async {
    final s = currentSong;
    final c = container.read(clientProvider);
    if (s == null || c == null) return;
    final starred = rating.hasHeart();
    try {
      starred ? await c.star(id: s.id) : await c.unstar(id: s.id);
      updateSong(s.copyWith(starred: starred));
      container.read(heartsProvider.notifier).set(s.id, starred);
    } catch (_) {} // offline: the heart stays as it was
  }

  @override
  Future<void> onTaskRemoved() => _saveQueue();

  // ── Broadcasting to the notification / UI ──
  void _broadcastQueue() {
    queue.add(_songs.map(_mediaItem).toList());
    _fetchAll(); // songs you don't have that just came into the queue: start getting them
  }

  void _broadcast(PlaybackEvent event) {
    final playing = player.playing;
    final starred = currentSong?.starred ?? false;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.custom(
            androidIcon: starred ? 'drawable/ic_heart_filled' : 'drawable/ic_heart',
            label: starred ? 'Unfavourite' : 'Favourite',
            name: 'toggleStar',
          ),
          MediaControl.custom(
            androidIcon: switch (_shuffleKind) {
              ShuffleKind.off => 'drawable/ic_aa_shuffle_off',
              ShuffleKind.on => 'drawable/ic_aa_shuffle',
              ShuffleKind.smart => 'drawable/ic_aa_shuffle_smart',
            },
            label: switch (_shuffleKind) {
              ShuffleKind.off => 'Shuffle',
              ShuffleKind.on => 'Smart shuffle',
              ShuffleKind.smart => 'Shuffle off',
            },
            name: 'cycleShuffle',
          ),
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setRating,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[player.processingState]!,
        playing: playing,
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        queueIndex: event.currentIndex,
        shuffleMode: switch (_shuffleKind) {
          ShuffleKind.off => AudioServiceShuffleMode.none,
          ShuffleKind.on => AudioServiceShuffleMode.all,
          ShuffleKind.smart => AudioServiceShuffleMode.group,
        },
        repeatMode: switch (player.loopMode) {
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
          LoopMode.off => AudioServiceRepeatMode.none,
        },
      ),
    );
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    // desktop: Plasma's media controls (MPRIS) set the volume
    if (name == 'dbusVolume' && isDesktop) {
      final v = extras?['value'];
      if (v is num) await setDesktopVolume(v.toDouble().clamp(0.0, 1.0));
      return null;
    }
    if (name == 'toggleStar') {
      final s = currentSong;
      if (s != null) await setRating(Rating.newHeartRating(!s.starred));
    }
    if (name == 'cycleShuffle') {
      await setShuffleKind(switch (_shuffleKind) {
        ShuffleKind.off => ShuffleKind.on,
        ShuffleKind.on => ShuffleKind.smart,
        ShuffleKind.smart => ShuffleKind.off,
      });
    }
  }

  // ── Android Auto / media browsers ──
  static const _root = AudioService.browsableRootId;
  static const _grid = {AndroidContentStyle.browsableHintKey: AndroidContentStyle.gridItemHintValue};

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    final repo = container.read(repoProvider);
    final c = container.read(clientProvider);
    Uri? art(String id) => _carArtUri(c, id);
    MediaItem songItem(Song s, String id) => _mediaItem(s).copyWith(id: id, playable: true, artUri: art(s.coverArt));
    MediaItem folder(String id, String title, {Map<String, dynamic>? extras, String? subtitle}) =>
        MediaItem(id: id, title: title, playable: false, extras: extras, displaySubtitle: subtitle);
    MediaItem action(String id, String title, {String? subtitle, Uri? artUri}) =>
        MediaItem(id: id, title: title, playable: true, displaySubtitle: subtitle, artUri: artUri);
    MediaItem albumItem(Album a) =>
        MediaItem(id: 'album:${a.id}', title: a.name, artist: a.artist, playable: false, artUri: art(a.coverArt));
    try {
      switch (parentMediaId) {
        case AudioService.recentRootId:
          final cur = currentSong;
          return cur == null ? const [] : [songItem(cur, 'resume:${cur.id}')];
        case _root: // up to four tabs in the car
          return [
            folder('home', 'Home'),
            folder('playlists', 'Playlists'),
            folder('albums', 'Albums', extras: _grid),
            folder('radio', 'Radio'),
          ];
        case 'home':
          final online = repo.online;
          return [
            action('mix:liked', 'Liked songs', subtitle: 'Shuffle'),
            if (online) action('mix:liked-smart', 'Liked songs · smart shuffle', subtitle: 'With songs that fit'),
            if (online && container.read(aiProvider) != null)
              action('mix:foryou', 'Made for you', subtitle: 'From what you play most'),
            action('mix:downloads', 'Downloaded songs', subtitle: 'Shuffle, works offline'),
            action('mix:random', 'Shuffle everything'),
            if (online) folder('podcasts', 'New podcast episodes'),
            folder('list:recent', 'Recently played', extras: _grid),
            folder('list:newest', 'Recently added', extras: _grid),
          ];
        case 'albums':
          return [
            folder('list:starred', 'Favourite albums', extras: _grid),
            folder('list:frequent', 'Most played', extras: _grid),
            folder('list:newest', 'Recently added', extras: _grid),
            folder('list:random', 'Something different', extras: _grid),
          ];
        case 'playlists':
          return [
            for (final p in await repo.playlists())
              MediaItem(
                id: 'pl:${p.id}',
                title: p.name,
                displaySubtitle: '${p.songCount ?? 0} songs',
                playable: false,
                artUri: art(p.coverArt),
              ),
          ];
        case 'podcasts':
          final eps = c == null ? const <PodcastEpisode>[] : await c.newestEpisodes(count: 25);
          return [
            for (final e in eps.where((e) => !e.played))
              MediaItem(
                id: 'episode:${e.id}',
                title: e.title,
                artist: e.show,
                displaySubtitle: e.show,
                playable: true,
                artUri: art(e.coverArt),
              ),
          ];
        case 'radio':
          final stations = repo.online && c != null ? await c.radios() : const <InternetRadio>[];
          return [
            for (final r in stations) action('station:${r.id}', r.name, subtitle: 'Internet radio'),
            if (stations.isEmpty) MediaItem(id: 'none', title: 'No stations yet', playable: false),
          ];
      }
      if (parentMediaId.startsWith('list:')) {
        final type = parentMediaId.substring(5);
        if (type == 'starred') return (await repo.starred()).albums.map(albumItem).toList();
        return (await repo.albums(type, size: 40)).where((a) => !a.isLookup).map(albumItem).toList();
      }
      if (parentMediaId.startsWith('album:')) {
        final a = await repo.album(parentMediaId.substring(6));
        return [
          for (final s in a.songs.where((s) => !s.isLookup && canPlay(s)))
            songItem(s, 'song:${a.id}:${s.id}'),
        ];
      }
      if (parentMediaId.startsWith('pl:')) {
        final id = parentMediaId.substring(3);
        final p = await repo.playlist(id);
        return [
          action('plshuffle:$id', 'Shuffle', subtitle: p.name),
          for (final s in p.songs.where((s) => !s.isLookup && canPlay(s)).take(300))
            songItem(s, 'plsong:$id:${s.id}'),
        ];
      }
    } catch (_) {}
    return const [];
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final repo = container.read(repoProvider);
    final p = mediaId.split(':');
    switch (p.first) {
      case 'resume':
        return play(); // the restored queue is already loaded
      case 'mix':
        switch (p.length > 1 ? p[1] : '') {
          case 'random':
            return playSongs(await repo.randomSongs(size: 200), shuffle: true);
          case 'liked' || 'liked-smart':
            await playSongs((await repo.starred()).songs, shuffle: true, context: const PlayContext.liked());
            final want = p[1] == 'liked-smart' ? ShuffleKind.smart : ShuffleKind.on;
            if (_shuffleKind != want) await setShuffleKind(want);
            return;
          case 'foryou':
            final ai = container.read(aiProvider);
            if (ai != null) return playSongs(await ai.forYou());
            return;
          case 'downloads':
            final songs = [for (final (s, _, _) in await container.read(dbProvider).downloads()) s];
            return playSongs(songs, shuffle: true, source: 'downloads');
        }
      case 'episode':
        final e = await container.read(clientProvider)?.podcastEpisode(p[1]);
        if (e != null) return playEpisode(e);
      case 'station':
        final c = container.read(clientProvider);
        final r = (await c?.radios() ?? const <InternetRadio>[]).where((x) => x.id == p[1]).firstOrNull;
        if (r != null) return playRadio(r);
      case 'playlist' || 'plshuffle':
        final pl = await repo.playlist(p[1]);
        return playSongs(pl.songs, shuffle: p.first == 'plshuffle', context: PlayContext.playlist(pl.id, pl.name));
      case 'plsong':
        final pl = await repo.playlist(p[1]);
        final songs = pl.songs.where((s) => !s.isLookup).toList();
        return playSongs(
          songs,
          index: max(0, songs.indexWhere((s) => s.id == p[2])),
          context: PlayContext.playlist(pl.id, pl.name),
        );
      case 'song':
        final a = await repo.album(p[1]);
        final songs = a.songs.where((s) => !s.isLookup).toList();
        return playSongs(
          songs,
          index: max(0, songs.indexWhere((s) => s.id == p[2])),
          context: PlayContext.album(a.id, a.name),
        );
    }
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    final repo = container.read(repoProvider);
    if (query.trim().isEmpty) return playSongs(await repo.randomSongs(size: 200), shuffle: true); // "play music"
    final r = await repo.search(query);
    if (r.songs.isNotEmpty) return playSongs(r.songs.where((s) => !s.isLookup).toList());
    final album = r.albums.where((a) => !a.isLookup).firstOrNull;
    if (album != null) return playSongs((await repo.album(album.id)).songs);
    if (r.artists.isNotEmpty) {
      final a = await repo.artist(r.artists.first.id);
      final songs = <Song>[];
      for (final al in a.albums.take(10)) {
        songs.addAll((await repo.album(al.id)).songs.where((s) => !s.isLookup));
      }
      return playSongs(songs, shuffle: true);
    }
  }
}

late EncoreAudioHandler audioHandler; // created in main()

/// Short messages from the player for the app to show (e.g. nothing playable while offline).
final playerNotices = StreamController<String>.broadcast();

/// A problem on the server side worth a banner (null: none).
final serverTrouble = ValueNotifier<String?>(null);

/// The speaker being cast to (null: playing on the phone).
class CastInfo {
  const CastInfo(this.name, {this.connecting = false, this.volume = 1});
  final String name;
  final bool connecting;
  final double volume;
}

final castInfo = ValueNotifier<CastInfo?>(null);
