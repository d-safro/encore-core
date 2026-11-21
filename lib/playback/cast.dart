import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

import '../core/platform.dart';

/// Chromecast and other Google Cast speakers / TVs, without Google Play Services: found on the Wi-Fi with
/// mDNS, controlled over the Cast protocol (TLS on port 8009), playing through Google's standard media
/// receiver. The audio comes from a small relay in the app (see [CastRelay]), because the speaker usually
/// can't reach your server itself (e.g. when the server is only on Tailscale).
class CastDevice {
  const CastDevice(this.name, this.host, this.port, {this.model = '', this.location});
  final String name, host, model;
  final int port;
  final String? location; // a UPnP / DLNA renderer's description address (upnp.dart); null: Google Cast
  bool get isUpnp => location != null;
  @override
  bool operator ==(Object other) => other is CastDevice && other.host == host && other.port == port;
  @override
  int get hashCode => Object.hash(host, port);
}

const _system = MethodChannel('encore/system');

/// The desktop's port for the speaker to fetch the music from.
const castRelayPort = 4547;

/// Cast devices on this Wi-Fi (looks for about [wait]).
Future<List<CastDevice>> findCastDevices({Duration wait = const Duration(seconds: 4)}) async {
  // Android drops multicast packets unless an app holds a multicast lock
  try {
    await _system.invokeMethod('multicastLock', {'on': true});
  } catch (_) {}
  final client = MDnsClient(
    rawDatagramSocketFactory: (dynamic host, int port, {bool reuseAddress = true, bool reusePort = false, int ttl = 1}) =>
        RawDatagramSocket.bind(host, port, reuseAddress: true, reusePort: false, ttl: ttl),
  );
  final found = <CastDevice>{};
  try {
    await client.start();
    final deadline = DateTime.now().add(wait);
    await for (final ptr in client
        .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer('_googlecast._tcp.local'))
        .timeout(wait, onTimeout: (s) => s.close())) {
      if (DateTime.now().isAfter(deadline)) break;
      String name = ptr.domainName.split('._googlecast').first;
      var model = '';
      await for (final txt in client
          .lookup<TxtResourceRecord>(ResourceRecordQuery.text(ptr.domainName))
          .timeout(const Duration(seconds: 2), onTimeout: (s) => s.close())) {
        for (final line in txt.text.split('\n')) {
          if (line.startsWith('fn=')) name = line.substring(3);
          if (line.startsWith('md=')) model = line.substring(3);
        }
      }
      await for (final srv in client
          .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
          .timeout(const Duration(seconds: 2), onTimeout: (s) => s.close())) {
        await for (final ip in client
            .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target))
            .timeout(const Duration(seconds: 2), onTimeout: (s) => s.close())) {
          found.add(CastDevice(name, ip.address.address, srv.port, model: model));
        }
      }
    }
  } catch (_) {
    // no Wi-Fi / multicast blocked: nothing found
  } finally {
    client.stop();
    try {
      await _system.invokeMethod('multicastLock', {'on': false});
    } catch (_) {}
  }
  return found.toList()..sort((a, b) => a.name.compareTo(b.name));
}

// ── The Cast protocol: length-prefixed protobuf CastMessages carrying JSON ──
const _nsConnection = 'urn:x-cast:com.google.cast.tp.connection';
const _nsHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
const _nsReceiver = 'urn:x-cast:com.google.cast.receiver';
const _nsMedia = 'urn:x-cast:com.google.cast.media';
const _defaultReceiver = 'CC1AD845'; // Google's standard media receiver

List<int> _varint(int v) {
  final out = <int>[];
  while (v >= 0x80) {
    out.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.add(v);
  return out;
}

/// One Cast message on the wire (public for the tests).
Uint8List encodeCastMessage(String source, String dest, String ns, String json) {
  final b = BytesBuilder();
  void str(int field, String s) {
    final bytes = utf8.encode(s);
    b
      ..add(_varint(field << 3 | 2))
      ..add(_varint(bytes.length))
      ..add(bytes);
  }

  b
    ..add(_varint(1 << 3))
    ..add(_varint(0)); // protocol_version CASTV2_1_0
  str(2, source);
  str(3, dest);
  str(4, ns);
  b
    ..add(_varint(5 << 3))
    ..add(_varint(0)); // payload_type STRING
  str(6, json);
  final body = b.toBytes();
  final out = ByteData(4)..setUint32(0, body.length);
  return Uint8List.fromList([...out.buffer.asUint8List(), ...body]);
}

/// (source, destination, namespace, payload) from one message.
(String, String, String, String) decodeCastMessage(Uint8List m) {
  var i = 0;
  int varint() {
    var shift = 0, v = 0;
    while (true) {
      final x = m[i++];
      v |= (x & 0x7f) << shift;
      if (x < 0x80) return v;
      shift += 7;
    }
  }

  final f = <int, String>{};
  while (i < m.length) {
    final key = varint();
    final wire = key & 7, field = key >> 3;
    if (wire == 0) {
      varint();
    } else if (wire == 2) {
      final len = varint();
      if (field >= 2 && field <= 4 || field == 6) f[field] = utf8.decode(m.sublist(i, i + len), allowMalformed: true);
      i += len;
    } else {
      break; // nothing else is used by the Cast protocol
    }
  }
  return (f[2] ?? '', f[3] ?? '', f[4] ?? '', f[6] ?? '');
}

/// What the speaker reports about playback.
class CastMediaStatus {
  const CastMediaStatus(this.state, this.position, {this.idleReason});
  final String state; // PLAYING, PAUSED, BUFFERING, IDLE
  final Duration position;
  final String? idleReason; // FINISHED, ERROR, CANCELLED, INTERRUPTED
}

/// A speaker playing what Encore plays: Google Cast ([CastSession]) or UPnP / DLNA ([UpnpSession] in upnp.dart).
abstract class RemoteSpeaker {
  CastDevice get device;
  StreamController<CastMediaStatus> get status;
  Completer<void> get closed;
  double get volume;
  bool get isOpen;
  Future<void> load(String url, {
    required String contentType,
    required String title,
    String artist,
    String album,
    String? image,
    Duration position,
    bool play,
  });
  void play();
  void pause();
  void seek(Duration to);
  void setVolume(double level);
  Future<void> close({bool stopApp = true});
}

/// A connection to one speaker, with the media receiver running.
class CastSession implements RemoteSpeaker {
  CastSession._(this.device, this._socket);
  @override
  final CastDevice device;
  final SecureSocket _socket;
  final _buf = BytesBuilder();
  var _reqId = 1;
  String? _transport, _sessionId;
  int? _mediaSessionId;
  Timer? _ping;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  @override
  final status = StreamController<CastMediaStatus>.broadcast();
  @override
  final closed = Completer<void>();
  @override
  double volume = 1;

  static Future<CastSession> connect(CastDevice d) async {
    final socket = await SecureSocket.connect(
      d.host,
      d.port,
      onBadCertificate: (_) => true, // Cast devices use their own self-signed certificates
      timeout: const Duration(seconds: 8),
    );
    final s = CastSession._(d, socket);
    socket.listen(s._onData, onDone: s._onClosed, onError: (_) => s._onClosed(), cancelOnError: true);
    s._send('receiver-0', _nsConnection, {'type': 'CONNECT'});
    s._ping = Timer.periodic(const Duration(seconds: 5), (_) => s._send('receiver-0', _nsHeartbeat, {'type': 'PING'}));
    final launched = await s._request('receiver-0', _nsReceiver, {'type': 'LAUNCH', 'appId': _defaultReceiver},
        wait: const Duration(seconds: 20));
    s._readReceiver(launched);
    if (s._transport == null) {
      // the answer can come before the app is fully up: ask again
      await Future.delayed(const Duration(seconds: 1));
      s._readReceiver(await s._request('receiver-0', _nsReceiver, {'type': 'GET_STATUS'}));
    }
    if (s._transport == null) {
      await s.close();
      throw Exception("${d.name} didn't start the player");
    }
    s._send(s._transport!, _nsConnection, {'type': 'CONNECT'});
    return s;
  }

  @override
  bool get isOpen => !closed.isCompleted;

  void _readReceiver(Map<String, dynamic> j) {
    final st = j['status'] as Map?;
    for (final a in (st?['applications'] as List? ?? const [])) {
      if (a is Map && a['appId'] == _defaultReceiver) {
        _transport = a['transportId'] as String?;
        _sessionId = a['sessionId'] as String?;
      }
    }
    final v = (st?['volume'] as Map?)?['level'];
    if (v is num) volume = v.toDouble();
  }

  void _send(String dest, String ns, Map<String, dynamic> payload) {
    if (!isOpen) return;
    try {
      _socket.add(encodeCastMessage('sender-0', dest, ns, jsonEncode(payload)));
    } catch (_) {
      _onClosed();
    }
  }

  Future<Map<String, dynamic>> _request(String dest, String ns, Map<String, dynamic> payload,
      {Duration wait = const Duration(seconds: 10)}) {
    final id = _reqId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _send(dest, ns, {...payload, 'requestId': id});
    return c.future.timeout(wait, onTimeout: () {
      _pending.remove(id);
      return const {};
    });
  }

  void _onData(Uint8List data) {
    _buf.add(data);
    var bytes = _buf.takeBytes();
    while (bytes.length >= 4) {
      final len = ByteData.sublistView(bytes, 0, 4).getUint32(0);
      if (bytes.length < 4 + len) break;
      _onMessage(decodeCastMessage(Uint8List.sublistView(bytes, 4, 4 + len)));
      bytes = Uint8List.sublistView(bytes, 4 + len);
    }
    _buf.add(bytes);
  }

  void _onMessage((String, String, String, String) m) {
    final (source, _, ns, payload) = m;
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(payload) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final type = j['type'];
    if (ns == _nsHeartbeat && type == 'PING') return _send(source, _nsHeartbeat, {'type': 'PONG'});
    if (ns == _nsConnection && type == 'CLOSE' && (source == _transport || source == 'receiver-0')) {
      return _onClosed(); // someone else took over the speaker, or it stopped the app
    }
    if (ns == _nsReceiver && type == 'RECEIVER_STATUS') {
      _readReceiver(j);
      final apps = (j['status'] as Map?)?['applications'] as List?;
      if (_transport != null && (apps == null || !apps.any((a) => a is Map && a['appId'] == _defaultReceiver))) {
        _onClosed(); // our player was closed on the speaker
      }
    }
    if (ns == _nsMedia && type == 'MEDIA_STATUS') {
      for (final s in (j['status'] as List? ?? const [])) {
        if (s is! Map) continue;
        _mediaSessionId = (s['mediaSessionId'] as num?)?.toInt() ?? _mediaSessionId;
        status.add(CastMediaStatus(
          '${s['playerState'] ?? 'IDLE'}',
          Duration(milliseconds: (((s['currentTime'] as num?) ?? 0) * 1000).round()),
          idleReason: s['idleReason'] as String?,
        ));
      }
    }
    final id = (j['requestId'] as num?)?.toInt();
    if (id != null) _pending.remove(id)?.complete(j);
  }

  void _onClosed() {
    if (closed.isCompleted) return;
    _ping?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(const {});
    }
    _pending.clear();
    closed.complete();
    status.close();
    try {
      _socket.destroy();
    } catch (_) {}
  }

  /// Play [url] on the speaker from [position].
  @override
  Future<void> load(String url, {
    required String contentType,
    required String title,
    String artist = '',
    String album = '',
    String? image,
    Duration position = Duration.zero,
    bool play = true,
  }) async {
    final t = _transport;
    if (t == null) return;
    _mediaSessionId = null;
    await _request(t, _nsMedia, {
      'type': 'LOAD',
      'autoplay': play,
      'currentTime': position.inMilliseconds / 1000,
      'media': {
        'contentId': url,
        'contentType': contentType,
        'streamType': 'BUFFERED',
        'metadata': {
          'metadataType': 3, // a music track
          'title': title,
          'artist': artist,
          'albumName': album,
          if (image != null) 'images': [
            {'url': image},
          ],
        },
      },
    }, wait: const Duration(seconds: 20));
  }

  void _media(Map<String, dynamic> p) {
    final t = _transport, id = _mediaSessionId;
    if (t == null || id == null) return;
    _send(t, _nsMedia, {...p, 'mediaSessionId': id, 'requestId': _reqId++});
  }

  @override
  void play() => _media({'type': 'PLAY'});
  @override
  void pause() => _media({'type': 'PAUSE'});
  @override
  void seek(Duration to) => _media({'type': 'SEEK', 'currentTime': to.inMilliseconds / 1000});

  @override
  void setVolume(double level) {
    volume = level.clamp(0, 1).toDouble();
    _send('receiver-0', _nsReceiver, {'type': 'SET_VOLUME', 'volume': {'level': volume}, 'requestId': _reqId++});
  }

  /// Stops the player on the speaker and disconnects.
  @override
  Future<void> close({bool stopApp = true}) async {
    if (!isOpen) return;
    if (stopApp && _sessionId != null) {
      _send('receiver-0', _nsReceiver, {'type': 'STOP', 'sessionId': _sessionId, 'requestId': _reqId++});
      await Future.delayed(const Duration(milliseconds: 300));
    }
    _send('receiver-0', _nsConnection, {'type': 'CLOSE'});
    _onClosed();
  }
}

/// The speaker fetches songs and covers from here (the phone, on the Wi-Fi), and the phone gets them from
/// your server (or plays its own downloaded copy). Addresses carry a random key, so other devices on the
/// Wi-Fi can't use it.
class CastRelay {
  CastRelay._(this._server, this.host, this._key);
  final HttpServer _server;
  final String host, _key;
  final _http = HttpClient()..idleTimeout = const Duration(seconds: 30);

  /// song id → (where to get it: a server URL or a local file path, content type)
  final _songs = <String, (String, String)>{};
  final _art = <String, String>{};

  static Future<CastRelay?> start({String? host}) async {
    final ip = host ?? await _wifiAddress();
    if (ip == null) return null;
    // the desktop uses one known port, so a firewall can let the speaker in (README: firewall-cmd)
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, isDesktop ? castRelayPort : 0);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    final rnd = Random.secure();
    final key = List.generate(16, (_) => rnd.nextInt(16).toRadixString(16)).join();
    final r = CastRelay._(server, ip, key);
    server.listen(r._handle, onError: (_) {});
    return r;
  }

  /// The phone's address on the local network (not Tailscale or mobile data).
  static Future<String?> _wifiAddress() async {
    final all = await NetworkInterface.list(type: InternetAddressType.IPv4);
    bool private(String a) {
      final p = a.split('.').map(int.parse).toList();
      return p[0] == 10 || (p[0] == 172 && p[1] >= 16 && p[1] <= 31) || (p[0] == 192 && p[1] == 168);
    }

    String? best;
    for (final nic in all) {
      for (final a in nic.addresses) {
        if (!private(a.address)) continue;
        if (nic.name.startsWith('wlan') || nic.name.startsWith('eth')) return a.address;
        best ??= a.address;
      }
    }
    return best;
  }

  String songUrl(String id, String source, String contentType) {
    _songs[id] = (source, contentType);
    return 'http://$host:${_server.port}/$_key/song/${Uri.encodeComponent(id)}';
  }

  String artUrl(String coverId, String source) {
    _art[coverId] = source;
    return 'http://$host:${_server.port}/$_key/art/${Uri.encodeComponent(coverId)}';
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final parts = req.uri.pathSegments;
      if (parts.length != 3 || parts[0] != _key) {
        res.statusCode = HttpStatus.notFound;
        return await res.close();
      }
      final id = Uri.decodeComponent(parts[2]);
      res.headers.set('Access-Control-Allow-Origin', '*'); // the receiver is a web page
      // UPnP / DLNA renderers like to be told it's a stream they may seek in
      res.headers.set('transferMode.dlna.org', parts[1] == 'art' ? 'Interactive' : 'Streaming');
      res.headers.set('contentFeatures.dlna.org', 'DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000');
      if (parts[1] == 'art') {
        final src = _art[id];
        if (src == null) {
          res.statusCode = HttpStatus.notFound;
          return await res.close();
        }
        return await _proxy(req, src, null);
      }
      final song = _songs[id];
      if (song == null) {
        res.statusCode = HttpStatus.notFound;
        return await res.close();
      }
      final (src, type) = song;
      if (!src.startsWith('http')) return await _file(req, File(src), type);
      return await _proxy(req, src, type);
    } catch (_) {
      try {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _proxy(HttpRequest req, String url, String? type) async {
    final up = await _http.getUrl(Uri.parse(url));
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) up.headers.set(HttpHeaders.rangeHeader, range);
    final r = await up.close();
    final res = req.response;
    res.statusCode = r.statusCode;
    for (final h in [HttpHeaders.contentLengthHeader, HttpHeaders.contentRangeHeader, HttpHeaders.acceptRangesHeader]) {
      final v = r.headers.value(h);
      if (v != null) res.headers.set(h, v);
    }
    res.headers.contentType = ContentType.parse(type ?? r.headers.contentType?.toString() ?? 'application/octet-stream');
    if (req.method == 'HEAD') {
      await r.drain<void>();
      return res.close();
    }
    await res.addStream(r);
    await res.close();
  }

  Future<void> _file(HttpRequest req, File f, String type) async {
    final res = req.response;
    final len = await f.length();
    var start = 0, end = len - 1;
    final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (m != null) {
      if (m[1]!.isNotEmpty) start = int.parse(m[1]!);
      if (m[2]!.isNotEmpty) end = min(int.parse(m[2]!), len - 1);
      if (m[1]!.isEmpty && m[2]!.isNotEmpty) {
        start = len - int.parse(m[2]!);
        end = len - 1;
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$len');
    }
    res.headers
      ..contentType = ContentType.parse(type)
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentLength = end - start + 1;
    if (req.method == 'HEAD') return res.close();
    await res.addStream(f.openRead(start, end + 1));
    await res.close();
  }

  Future<void> stop() async {
    _http.close(force: true);
    await _server.close(force: true);
  }
}

/// What the speaker can play as it is; anything else is converted to MP3 on the server.
const castNative = {
  'mp3': 'audio/mpeg',
  'flac': 'audio/flac',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'oga': 'audio/ogg',
  'opus': 'audio/ogg',
  'wav': 'audio/wav',
  'webm': 'audio/webm',
};
