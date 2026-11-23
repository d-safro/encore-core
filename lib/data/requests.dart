import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';
import 'events.dart';
import 'subsonic.dart';

/// "Getting your songs": what the server is getting for you (Conductor's `encore.requests`, from 1.3): the ⬇ songs
/// you played (on trial), hearted or added to a playlist, your mixes' songs, and how getting each is going. An
/// admin sees everyone's and Lidarr's albums too, and can act on them (look again, set aside, stop, pick a file);
/// anyone else sees only their own, and no actions. Kept fresh by the event stream's `requests` event (Conductor
/// 1.4), else by asking every [requestsPollEvery] while it's shown.

/// How a request is going.
enum RequestState { searching, queued, downloading, done, notfound, failed, setAside, unknown }

RequestState _state(Object? v) => RequestState.values.firstWhere((s) => s.name == '$v', orElse: () => RequestState.unknown);

DateTime? _time(Object? v) => v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;
List<String> _strs(Object? v) => v is List ? [for (final x in v) '$x'] : const [];
String _s(Object? v) => v == null ? '' : '$v';
int _i(Object? v) => (v as num?)?.toInt() ?? 0;
double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

/// One song (or, for an admin, one of Lidarr's albums) asked for.
class ServerRequest {
  const ServerRequest({
    required this.id,
    this.type = 'song',
    this.title = '',
    this.artist = '',
    this.album = '',
    this.duration = 0,
    this.state = RequestState.searching,
    this.progress = 0,
    this.reasons = const [],
    this.users = const [],
    this.trial = false,
    this.kept = true,
    this.upgrading = false,
    this.asked,
    this.arrived,
    this.songId,
    this.actions = const {},
    this.note = '',
    this.query = '',
    this.from = '',
    this.file = '',
  });

  final String id, type, title, artist, album;
  final int duration; // seconds
  final RequestState state;
  final double progress; // 0–100, while downloading
  final List<String> reasons; // heart, playlist, trial, mix, discovery, lidarr
  final List<String> users; // who asked (an admin sees everyone's names)
  final bool trial, kept, upgrading;
  final DateTime? asked, arrived;
  final String? songId; // the library song, once it's here
  final Set<String> actions; // what you may do with it now: retry, cancel, setAside, bringBack, search, pick
  final String note, query, from, file; // (from, file: admins only)

  bool get isAlbum => type == 'album';
  bool get onTheWay =>
      state == RequestState.searching || state == RequestState.queued || state == RequestState.downloading;
  bool get missing => state == RequestState.notfound || state == RequestState.failed || state == RequestState.setAside;

  factory ServerRequest.fromJson(Map<String, dynamic> j) => ServerRequest(
    id: _s(j['id']),
    type: _s(j['type']).isEmpty ? 'song' : _s(j['type']),
    title: _s(j['title']),
    artist: _s(j['artist']),
    album: _s(j['album']),
    duration: _i(j['duration']),
    state: _state(j['state']),
    progress: _d(j['progress']).clamp(0, 100).toDouble(),
    reasons: _strs(j['reasons']),
    users: _strs(j['users']),
    trial: j['trial'] == true,
    kept: j['kept'] != false,
    upgrading: j['upgrading'] == true,
    asked: _time(j['asked']),
    arrived: _time(j['arrived']),
    songId: _s(j['songId']).isEmpty ? null : _s(j['songId']),
    actions: _strs(j['actions']).toSet(),
    note: _s(j['note']),
    query: _s(j['query']),
    from: _s(j['from']),
    file: _s(j['file']),
  );
}

/// A page of `getRequests`.
class RequestList {
  const RequestList({
    this.total = 0,
    this.counts = const {},
    this.onTrial = 0,
    this.downloadsPaused = false,
    this.canPick = false,
    this.requests = const [],
  });
  final int total, onTrial;
  final Map<String, int> counts; // by state (searching, queued…), whatever was asked for
  final bool downloadsPaused, canPick;
  final List<ServerRequest> requests;

  int count(RequestState s) => counts[s.name] ?? 0;

  factory RequestList.fromJson(Map<String, dynamic> j) {
    final counts = j['counts'] is Map ? (j['counts'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    return RequestList(
      total: _i(j['total']),
      counts: {for (final e in counts.entries) e.key: _i(e.value)},
      onTrial: _i(j['onTrial']),
      downloadsPaused: j['downloadsPaused'] == true,
      canPick: j['canPick'] == true,
      requests: [
        for (final r in (j['request'] is List ? j['request'] as List : const []))
          if (r is Map) ServerRequest.fromJson(r.cast<String, dynamic>()),
      ],
    );
  }
}

/// A file a Soulseek search found for a request (`searchRequestFiles`), for an admin to pick.
class RequestFile {
  const RequestFile({
    required this.user,
    required this.filename,
    this.size = 0,
    this.name = '',
    this.folder = '',
    this.ext = '',
    this.bitrate = 0,
    this.length = 0,
    this.free = false,
    this.queue = 0,
    this.match = false,
    this.titleOk = false,
    this.artistOk = false,
    this.sameAlbum = false,
  });
  final String user, filename, name, folder, ext;
  final int size, bitrate, queue;
  final double length; // seconds
  final bool free, match, titleOk, artistOk, sameAlbum;

  factory RequestFile.fromJson(Map<String, dynamic> j) => RequestFile(
    user: _s(j['user']),
    filename: _s(j['filename']),
    size: _i(j['size']),
    name: _s(j['name']),
    folder: _s(j['folder']),
    ext: _s(j['ext']),
    bitrate: _i(j['bitrate']),
    length: _d(j['length']),
    free: j['free'] == true,
    queue: _i(j['queue']),
    match: j['match'] == true,
    titleOk: j['titleOk'] == true,
    artistOk: j['artistOk'] == true,
    sameAlbum: j['sameAlbum'] == true,
  );
}

class RequestFiles {
  const RequestFiles({this.query = '', this.total = 0, this.files = const []});
  final String query;
  final int total;
  final List<RequestFile> files;

  factory RequestFiles.fromJson(Map<String, dynamic> j) => RequestFiles(
    query: _s(j['query']),
    total: _i(j['total']),
    files: [
      for (final f in (j['file'] is List ? j['file'] as List : const []))
        if (f is Map) RequestFile.fromJson(f.cast<String, dynamic>()),
    ],
  );
}

Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

/// The `encore.requests` calls.
extension RequestCalls on SubsonicClient {
  /// [states]: only these (none: all); newest first.
  Future<RequestList> requests({List<RequestState> states = const [], String? type, int offset = 0, int count = 50}) async {
    final r = await call('getRequests', {
      if (states.isNotEmpty) 'state': states.map((s) => s.name).join(','),
      'type': ?type,
      'offset': offset,
      'count': count,
    });
    return RequestList.fromJson(_m(r['requests']));
  }

  /// The songs put on trial today and how many may be (from `lookupSongs`, asked about no song); null when the
  /// server doesn't say.
  Future<TrialBudget?> trialsToday() async {
    final j = _m((await call('lookupSongs'))['lookupSongs']);
    if (j['usedToday'] is! num || j['perDay'] is! num) return null;
    return TrialBudget(
      _i(j['usedToday']),
      _i(j['perDay']),
      hours: (j['trialHours'] as num?)?.toDouble() ?? 24,
      playlistId: _s(j['playlistId']),
    );
  }

  /// Admins: look again from the start.
  Future<ServerRequest> retryRequest(String id) async =>
      ServerRequest.fromJson(_m((await call('retryRequest', {'id': id}))['request']));

  /// Admins: stop getting a song that isn't here yet.
  Future<void> cancelRequest(String id) => call('cancelRequest', {'id': id});

  /// Admins: no more automatic searches for it ([aside]), or bring it back.
  Future<ServerRequest> setRequestAside(String id, {bool aside = true}) async =>
      ServerRequest.fromJson(_m((await call('setRequestAside', {'id': id, 'aside': aside}))['request']));

  /// Admins: search Soulseek for it (in [query]'s words, else its own). Waits for the search: up to 40 s.
  Future<RequestFiles> searchRequestFiles(String id, {String? query}) async => RequestFiles.fromJson(
    _m((await call('searchRequestFiles', {'id': id, 'query': ?query}, null, const Duration(seconds: 90)))['requestFiles']),
  );

  /// Admins: download this file for it.
  Future<ServerRequest> pickRequestFile(String id, RequestFile f) async => ServerRequest.fromJson(
    _m((await call('pickRequestFile', {'id': id, 'user': f.user, 'file': f.filename, 'size': f.size}))['request']),
  );
}

/// Songs put on trial today, of at most [perDay]; each is deleted [hours] after it arrives unless it's kept. They
/// wait in your "On trial" playlist ([playlistId], '' before there is one).
class TrialBudget {
  const TrialBudget(this.today, this.perDay, {this.hours = 24, this.playlistId = ''});
  final int today, perDay;
  final double hours;
  final String playlistId;
}

/// Whether the server tells what it's getting (`encore.requests`). Asked again soon when the server didn't answer.
final requestsOfferedProvider = FutureProvider<bool>((ref) async {
  final c = ref.watch(clientProvider);
  if (c == null) return false;
  final names = await c.openSubsonicExtensions();
  if (names.isEmpty) {
    // no answer (offline, say): ask again soon rather than keep "no"
    final again = Timer(const Duration(seconds: 30), ref.invalidateSelf);
    ref.onDispose(again.cancel);
  }
  return names.contains('encore.requests');
});

/// What the screen shows: what's not here yet (on its way, not found, set aside), the newest arrivals, and the
/// trials today.
class RequestsView {
  const RequestsView({this.pending = const RequestList(), this.arrived = const [], this.trials});
  final RequestList pending;
  final List<ServerRequest> arrived;
  final TrialBudget? trials;

  List<ServerRequest> get onTheWay => [for (final r in pending.requests) if (r.onTheWay) r];
  List<ServerRequest> get missing => [for (final r in pending.requests) if (r.missing) r];
  int get onTheWayCount =>
      pending.count(RequestState.searching) + pending.count(RequestState.queued) + pending.count(RequestState.downloading);
  bool get isEmpty => pending.requests.isEmpty && arrived.isEmpty;
}

/// How often the list is asked for again while it's shown and the server can't tell of changes itself (no event
/// stream, or one without `requests` events).
const requestsPollEvery = Duration(seconds: 30);

/// The newest arrivals shown.
const requestsArrivedShown = 30;

/// What the server is getting for you; null when it doesn't say (Navidrome, older Conductor) or you're signed out.
class RequestsNotifier extends AsyncNotifier<RequestsView?> {
  bool _loading = false, _again = false;

  @override
  Future<RequestsView?> build() async {
    final c = ref.watch(clientProvider);
    if (c == null || !await ref.watch(requestsOfferedProvider.future)) return null;
    final live = ref.watch(liveEventsProvider);
    final sub = live?.events.listen((e) {
      if (e.type == 'requests' || e.type == 'resync') unawaited(refresh());
    });
    final timer = Timer.periodic(requestsPollEvery, (_) {
      final told = live != null && live.healthy && live.serverEvents.contains('requests');
      if (!told) unawaited(refresh());
    });
    ref.onDispose(() {
      sub?.cancel();
      timer.cancel();
    });
    return _load(c);
  }

  static Future<RequestsView> _load(SubsonicClient c) async {
    final pending = c.requests(
      states: const [
        RequestState.searching,
        RequestState.queued,
        RequestState.downloading,
        RequestState.notfound,
        RequestState.failed,
        RequestState.setAside,
      ],
      count: 200,
    );
    final done = c.requests(states: const [RequestState.done], count: 100);
    final trials = c.trialsToday().then<TrialBudget?>((t) => t, onError: (_) => null);
    // (all at once, and an error from any of them is the answer's)
    final got = await Future.wait<Object?>([pending, done, trials]);
    final arrived = (got[1] as RequestList).requests.toList()
      ..sort((a, b) => (b.arrived ?? b.asked ?? DateTime(0)).compareTo(a.arrived ?? a.asked ?? DateTime(0)));
    return RequestsView(
      pending: got[0] as RequestList,
      arrived: arrived.take(requestsArrivedShown).toList(),
      trials: got[2] as TrialBudget?,
    );
  }

  /// Ask again (pull to refresh, an event, after an action). What's shown stays while it's asked, and when asking
  /// fails (then the error is thrown, for pull to refresh to show).
  Future<void> refresh() async {
    final c = ref.read(clientProvider);
    if (c == null || state.value == null) return;
    if (_loading) {
      _again = true; // once more when this one's done: something changed meanwhile
      return;
    }
    _loading = true;
    try {
      do {
        _again = false;
        final v = await _load(c);
        if (!ref.mounted) return;
        state = AsyncData(v);
      } while (_again);
    } finally {
      _loading = false;
    }
  }

  /// After an admin's action: the list again (an action that failed is the caller's to say).
  Future<void> acted() => refresh().catchError((_) {});
}

final requestsProvider = AsyncNotifierProvider.autoDispose<RequestsNotifier, RequestsView?>(RequestsNotifier.new);
