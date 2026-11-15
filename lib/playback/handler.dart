import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../core/settings.dart';
import '../data/account.dart';
import '../data/ai.dart';
import '../data/library.dart';
import '../data/models.dart';
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
/// background with the media notification, lock-screen and Bluetooth controls and Android Auto.
class EncoreAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  EncoreAudioHandler(this.container) {
    _init();
  }

  final ProviderContainer container;
  final equalizer = AndroidEqualizer();
  final loudness = AndroidLoudnessEnhancer();
  late final AudioPlayer player = AudioPlayer(audioPipeline: AudioPipeline(androidAudioEffects: [equalizer, loudness]));

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
  bool _fetchingRadio = false;
  Song? radioSeed; // set while a song radio is playing: the queue keeps growing with songs like it

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

  Settings get _settings => container.read(settingsProvider);

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    player.playbackEventStream.listen(
      _broadcast,
      onError: (Object e, StackTrace st) async {
        // a song that can't be played (server gone, file missing): skip it instead of stopping
        container.read(serverReachableProvider.notifier).suspect();
        await _skipToPlayable();
      },
    );
    player.currentIndexStream.listen(_onIndex);
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
      if (!playing && _fadeFrom != null) _cancelFade(); // paused mid-blend: the rest plays plainly
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
      if (s == ProcessingState.completed || s == ProcessingState.idle) _reportSoon();
    });
    container.listen(settingsProvider, (prev, next) => _applySettings(prev, next), fireImmediately: true);
    // going offline, or a song finishing its download: queued copies switch to the phone's file
    container.listen(offlineProvider, (prev, next) {
      if (next == true) useDownloadedFiles();
    });
    container.listen(downloadsProvider.select((d) => d.files.length), (prev, next) {
      if (next > (prev ?? 0)) useDownloadedFiles();
    });
    await _restoreQueue();
  }

  // ── Settings that act on the player ──
  Future<void> _applySettings(Settings? prev, Settings s) async {
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
  }

  Future<void> _quiet(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {} // audio effects can fail before the first song is loaded; they're set again later
  }

  /// Volume from ReplayGain tags. Quieter-than-reference songs use the player volume; louder needs the
  /// loudness enhancer (Android can't amplify through volume alone).
  void _applyReplayGain() {
    final i = player.currentIndex;
    final s = _settings;
    if (i == null || i >= _songs.length || s.replayGain == ReplayGainMode.off) {
      _setMainVolume(1);
      _quiet(() => loudness.setEnabled(false));
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
      _quiet(() => loudness.setEnabled(false));
      return;
    }
    final peak = (albumMode ? rg.albumPeak ?? rg.trackPeak : rg.trackPeak ?? rg.albumPeak) ?? 1.0;
    var db = gain + s.replayGainPreamp;
    if (peak > 0) db = min(db, -20 * log(peak) / ln10); // never push past full scale
    if (db <= 0) {
      _quiet(() => loudness.setEnabled(false));
      _setMainVolume(pow(10, db / 20).toDouble());
    } else {
      _setMainVolume(1);
      _quiet(() => loudness.setTargetGain(db));
      _quiet(() => loudness.setEnabled(true));
    }
  }

  /// The ReplayGain volume of the playing song; during a crossfade the player plays a falling share of it.
  double _mainVolume = 1, _fadeShare = 1;
  void _setMainVolume(double v) {
    _mainVolume = v;
    _quiet(() => player.setVolume(v * _fadeShare));
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
    if (cf <= 0 || radioStation != null || i + 1 >= _songs.length || player.loopMode == LoopMode.one) return false;
    final a = _songs[i], b = _songs[i + 1];
    if (isPodcastId(a.id) || isPodcastId(b.id) || a.isLookup || b.isLookup) return false;
    if (!canPlay(b)) return false;
    // an album played in order stays seamless (live records, DJ mixes, concept albums)
    if (!_settings.crossfadeAlbums && a.albumId.isNotEmpty && a.albumId == b.albumId && (b.track ?? 0) == (a.track ?? 0) + 1) {
      return false;
    }
    return true;
  }

  void _fadeTick(Duration pos) {
    if (!player.playing) return;
    final i = player.currentIndex, dur = player.duration;
    if (i == null || dur == null || dur <= Duration.zero) return;
    final left = dur - pos;
    final cf = Duration(seconds: _settings.crossfade);
    if (_fadeFrom != null && _fadeFrom != i) _cancelFade(); // moved somewhere else
    if (_fadeFrom == null && left <= cf + const Duration(seconds: 6) && left > cf && _fadeAllowed(i)) {
      _prepareFade(i); // load the next song a few seconds early so the fade starts on time
    }
    if (_fadeFrom == i && _fadeReady && _fadeTimer == null && left <= cf && left > const Duration(milliseconds: 500)) {
      _runFade(i, left);
    }
  }

  Future<void> _prepareFade(int i) async {
    _fadeFrom = i;
    _fadeReady = false;
    // shares the main player's audio focus: it must not pause the main player when it starts
    final fp = _fadePlayer ??= AudioPlayer(handleInterruptions: false, handleAudioSessionActivation: false);
    try {
      await fp.setVolume(0);
      await fp.setAudioSource(_source(_songs[i + 1]), preload: true);
      await fp.setSpeed(player.speed);
      if (_fadeFrom == i) _fadeReady = true;
    } catch (_) {
      if (_fadeFrom == i) _fadeFrom = null; // can't load it: no fade this time, plain gapless change
    }
  }

  void _runFade(int i, Duration left) {
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
      if (x >= 1) t.cancel();
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
    final set = _settings;
    final wifi = container.read(onWifiProvider);
    final fmt = wifi ? set.wifiFormat : set.mobileFormat;
    final rate = wifi ? set.wifiBitrate : set.mobileBitrate;
    return AudioSource.uri(
      c.streamUrl(s.id, format: fmt, maxBitRate: fmt == 'raw' ? null : rate),
      tag: item,
    );
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
      artUri: c != null && s.coverArt.isNotEmpty ? c.stableCoverUrl(s.coverArt) : null,
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
    playContext = context;
    playSource = source ?? context?.key;
    var list = songs.where((s) => (allowLookup || !s.isLookup) && canPlay(s)).toList();
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
  }

  /// Load a new queue. If the first song can't be loaded (server down, file gone, unreadable file), start
  /// from the next one that loads. False when none would (nothing should then claim to be playing).
  Future<bool> _load(List<Song> list, int index, {Duration? position, bool quiet = false}) async {
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
        if (i != index && !quiet) playerNotices.add("Couldn't play \"${list[index].title}\", skipped it");
        _loaded = true;
        return true;
      } on PlayerException catch (_) {
        container.read(serverReachableProvider.notifier).suspect();
      } on PlayerInterruptedException catch (_) {
        return false; // replaced by a newer request
      }
    }
    _loaded = false;
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
    final add = songs.where((s) => !s.isLookup && canPlay(s)).toList();
    if (add.isEmpty) return;
    if (_songs.isEmpty || radioStation != null) return playSongs(add);
    at = at.clamp((player.currentIndex ?? -1) + 1, _songs.length);
    _original?.addAll(add);
    _songs.insertAll(at, add);
    await player.insertAudioSources(at, add.map(_source).toList());
    _broadcastQueue();
    _scheduleSave();
  }

  Future<void> addLast(List<Song> songs) async {
    final add = songs.where((s) => !s.isLookup && canPlay(s)).toList();
    if (add.isEmpty) return;
    if (_songs.isEmpty) return playSongs(add);
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
    final o = _original?.indexWhere((s) => s.id == gone.id) ?? -1;
    if (o >= 0) _original!.removeAt(o);
    await player.removeAudioSourceAt(index);
    _broadcastQueue();
    _scheduleSave();
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
    await playSongs([seed, ...similar.where((s) => s.id != seed.id && !s.isLookup)]);
  }

  /// Song radio (like Spotify's): the song, then songs that sound like it; it never runs out.
  Future<bool> songRadio(Song seed) async {
    final c = container.read(clientProvider);
    if (c == null) return false;
    final similar = (await c.similarSongs(seed.id, count: 60)).where((s) => s.id != seed.id && !s.isLookup).toList();
    if (similar.isEmpty) return false;
    similar.shuffle();
    await playSongs([seed, ...similar.take(40)], radio: seed);
    return true;
  }

  Future<void> _maybeExtendRadio() async {
    final i = player.currentIndex;
    if (!(_settings.endlessRadio || radioSeed != null) || _fetchingRadio || i == null || i < _songs.length - 3) return;
    final c = container.read(clientProvider);
    if (c == null || container.read(offlineProvider)) return;
    _fetchingRadio = true;
    try {
      final have = _songs.map((s) => s.id).toSet();
      // a song radio stays close to its first song; endless playback follows where the music went
      final from = radioSeed != null && Random().nextBool()
          ? radioSeed!
          : _songs[Random().nextInt(max(1, _songs.length - i)) + min(i, _songs.length - 1)];
      final more = (await c.similarSongs(
        from.id,
        count: 30,
      )).where((s) => !s.isLookup && !have.contains(s.id)).take(15).toList();
      if (more.isNotEmpty) await addLast(more);
    } finally {
      _fetchingRadio = false;
    }
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
    final plainAfter = _songs.skip(last + 1).where((s) => !_suggested.contains(s.id)).length;
    if (plainAfter < 3 || last - i > 12) return;
    _filling = true;
    try {
      final picks = await _smartPicks(6);
      if (_shuffleKind != ShuffleKind.smart || picks.isEmpty) return;
      (i, last) = where(); // the queue may have moved on while fetching
      var pos = last + 1;
      {
        for (final p in picks) {
          var plain = 0;
          while (pos < _songs.length && plain < 3) {
            if (!_suggested.contains(_songs[pos].id)) plain++;
            pos++;
          }
          if (plain < 3) {
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
    final base = (_original ?? _songs).where((s) => !_suggested.contains(s.id) && !s.isLookup).toList();
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
    if (_fadeFrom != null) {
      _fadeFrom == i - 1 && _fadeTimer != null ? _handOff() : _cancelFade();
    }
    mediaItem.add(_mediaItem(s));
    _applyReplayGain();
    _listened = Duration.zero;
    _lastTick = null;
    _submitted = null;
    if (_settings.scrobble && _scrobbledNow != s.id && !isPodcastId(s.id) && !container.read(offlineProvider)) {
      _scrobbledNow = s.id;
      container.read(clientProvider)?.scrobble(s.id, submission: false).catchError((_) {});
    }
    _maybeExtendRadio();
    _smartFill();
    _scheduleSave();
    _reportSoon();
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
    if (s == null || _submitted == s.id || !_settings.scrobble) return;
    final len = Duration(seconds: s.duration ?? 240);
    final need = Duration(milliseconds: min(len.inMilliseconds ~/ 2, 240000));
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
    _reportSoon();
  }

  @override
  Future<void> skipToNext() => player.seekToNext();
  @override
  Future<void> skipToPrevious() async {
    if (player.position > const Duration(seconds: 4)) return player.seek(Duration.zero);
    return player.seekToPrevious();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _songs.length) return;
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
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) => player.setLoopMode(switch (repeatMode) {
    AudioServiceRepeatMode.one => LoopMode.one,
    AudioServiceRepeatMode.all || AudioServiceRepeatMode.group => LoopMode.all,
    _ => LoopMode.off,
  });

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
    Uri? art(String id, [int size = 300]) => c != null && id.isNotEmpty ? c.coverUrl(id, size: size) : null;
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
          return cur == null ? const [] : [_mediaItem(cur).copyWith(id: 'resume:${cur.id}', playable: true)];
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
            _mediaItem(s).copyWith(id: 'song:${a.id}:${s.id}', playable: true),
        ];
      }
      if (parentMediaId.startsWith('pl:')) {
        final id = parentMediaId.substring(3);
        final p = await repo.playlist(id);
        return [
          action('plshuffle:$id', 'Shuffle', subtitle: p.name),
          for (final s in p.songs.where((s) => !s.isLookup && canPlay(s)).take(300))
            _mediaItem(s).copyWith(id: 'plsong:$id:${s.id}', playable: true),
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
