import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cast.dart';

/// UPnP / DLNA speakers, TVs and receivers ("media renderers"): found with SSDP on the Wi-Fi, controlled with
/// SOAP (AVTransport to play, RenderingControl for the volume). They get the music from the same relay as
/// Cast speakers (the phone or computer fetches it from your server). Generic UPnP only: no Sonos quirks.

const _ssdp = '239.255.255.250';
const _avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';
const _rendering = 'urn:schemas-upnp-org:service:RenderingControl:1';

/// Renderers on this network (looks for about [wait]).
Future<List<CastDevice>> findUpnpRenderers({Duration wait = const Duration(seconds: 3)}) async {
  final locations = <String>{};
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.multicastHops = 4;
    final msg = utf8.encode([
      'M-SEARCH * HTTP/1.1',
      'HOST: $_ssdp:1900',
      'MAN: "ssdp:discover"',
      'MX: 2',
      'ST: urn:schemas-upnp-org:device:MediaRenderer:1',
      '',
      '',
    ].join('\r\n'));
    sock.send(msg, InternetAddress(_ssdp), 1900);
    Timer(const Duration(milliseconds: 600), () => sock?.send(msg, InternetAddress(_ssdp), 1900)); // UDP: twice
    await for (final e in sock.timeout(wait, onTimeout: (s) => s.close())) {
      if (e != RawSocketEvent.read) continue;
      final d = sock.receive();
      if (d == null) continue;
      final loc = ssdpLocation(utf8.decode(d.data, allowMalformed: true));
      if (loc != null) locations.add(loc);
    }
  } catch (_) {
  } finally {
    sock?.close();
  }
  final found = await Future.wait(locations.map((l) async {
    try {
      final xml = await _get(Uri.parse(l));
      final r = parseDescription(xml, Uri.parse(l));
      return r?.avTransport == null ? null : CastDevice(r!.name, Uri.parse(l).host, Uri.parse(l).port,
          model: r.model, location: l);
    } catch (_) {
      return null;
    }
  }));
  return found.whereType<CastDevice>().toList()..sort((a, b) => a.name.compareTo(b.name));
}

/// The LOCATION of an SSDP answer.
String? ssdpLocation(String answer) {
  for (final line in answer.split(RegExp(r'\r?\n'))) {
    final i = line.indexOf(':');
    if (i > 0 && line.substring(0, i).trim().toLowerCase() == 'location') return line.substring(i + 1).trim();
  }
  return null;
}

String? _tag(String xml, String tag) {
  final m = RegExp('<(?:\\w+:)?$tag(?:\\s[^>]*)?>([\\s\\S]*?)</(?:\\w+:)?$tag>').firstMatch(xml);
  return m == null ? null : _unescape(m[1]!.trim());
}

String _unescape(String s) =>
    s.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'").replaceAll('&amp;', '&');

String _escape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// A renderer's name, model and control addresses, from its device description.
class UpnpDescription {
  const UpnpDescription(this.name, this.model, this.avTransport, this.rendering);
  final String name, model;
  final Uri? avTransport, rendering;
}

UpnpDescription? parseDescription(String xml, Uri location) {
  final name = _tag(xml, 'friendlyName');
  if (name == null) return null;
  final given = Uri.tryParse(_tag(xml, 'URLBase') ?? '');
  final base = given != null && given.hasScheme ? given : location; // most renderers leave URLBase out
  Uri? control(String type) {
    for (final m in RegExp(r'<service>([\s\S]*?)</service>').allMatches(xml)) {
      final s = m[1]!;
      if ((_tag(s, 'serviceType') ?? '').startsWith(type.substring(0, type.length - 1))) {
        final u = _tag(s, 'controlURL');
        return u == null ? null : base.resolve(u);
      }
    }
    return null;
  }

  return UpnpDescription(name, [_tag(xml, 'manufacturer'), _tag(xml, 'modelName')].whereType<String>().join(' '),
      control(_avTransport), control(_rendering));
}

/// "0:03:25" (UPnP's time) <-> Duration.
String upnpTime(Duration d) =>
    '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

Duration parseUpnpTime(String? t) {
  final m = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d+))?').firstMatch(t ?? '');
  if (m == null) return Duration.zero;
  return Duration(hours: int.parse(m[1]!), minutes: int.parse(m[2]!), seconds: int.parse(m[3]!));
}

/// DIDL-Lite metadata: what the TV shows for the song.
String didl(String url, String contentType, String title, String artist, String album, String? image) =>
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
    '<item id="1" parentID="0" restricted="1"><dc:title>${_escape(title)}</dc:title>'
    '<upnp:artist>${_escape(artist)}</upnp:artist><upnp:album>${_escape(album)}</upnp:album>'
    '${image == null ? '' : '<upnp:albumArtURI>${_escape(image)}</upnp:albumArtURI>'}'
    '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
    '<res protocolInfo="http-get:*:$contentType:*">${_escape(url)}</res></item></DIDL-Lite>';

String soapBody(String service, String action, Map<String, String> args) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    '<s:Body><u:$action xmlns:u="$service">'
    '${args.entries.map((e) => '<${e.key}>${_escape(e.value)}</${e.key}>').join()}'
    '</u:$action></s:Body></s:Envelope>';

final _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);

Future<String> _get(Uri u) async {
  final req = await _http.getUrl(u).timeout(const Duration(seconds: 5));
  final res = await req.close().timeout(const Duration(seconds: 5));
  return utf8.decode(await res.fold<List<int>>([], (a, b) => a..addAll(b)), allowMalformed: true);
}

/// One renderer, playing what the phone plays.
class UpnpSession implements RemoteSpeaker {
  UpnpSession._(this.device, this._av, this._rc);
  @override
  final CastDevice device;
  final Uri _av;
  final Uri? _rc;
  @override
  final status = StreamController<CastMediaStatus>.broadcast();
  @override
  final closed = Completer<void>();
  @override
  double volume = 0.5;
  Timer? _poll;
  int _failures = 0;
  String _last = 'IDLE';

  static Future<UpnpSession> connect(CastDevice d) async {
    final desc = parseDescription(await _get(Uri.parse(d.location!)), Uri.parse(d.location!));
    if (desc?.avTransport == null) throw Exception("${d.name} doesn't take music to play");
    final s = UpnpSession._(d, desc!.avTransport!, desc.rendering);
    try {
      final v = await s._call(_rendering, 'GetVolume', {'InstanceID': '0', 'Channel': 'Master'});
      s.volume = (int.tryParse(_tag(v, 'CurrentVolume') ?? '') ?? 50) / 100;
    } catch (_) {}
    s._poll = Timer.periodic(const Duration(seconds: 1), (_) => s._status());
    return s;
  }

  @override
  bool get isOpen => !closed.isCompleted;

  Future<String> _call(String service, String action, Map<String, String> args) async {
    final url = service == _rendering ? _rc : _av;
    if (url == null) throw Exception('no $action');
    final req = await _http.postUrl(url).timeout(const Duration(seconds: 5));
    req.headers
      ..set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"')
      ..set('SOAPACTION', '"$service#$action"');
    req.add(utf8.encode(soapBody(service, action, args)));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final body = utf8.decode(await res.fold<List<int>>([], (a, b) => a..addAll(b)), allowMalformed: true);
    if (res.statusCode != 200) throw Exception('$action: ${_tag(body, 'errorDescription') ?? res.statusCode}');
    return body;
  }

  void _quiet(Future<void> Function() f) => f().catchError((_) {});

  Future<void> _status() async {
    if (!isOpen) return;
    try {
      final t = await _call(_avTransport, 'GetTransportInfo', {'InstanceID': '0'});
      final p = await _call(_avTransport, 'GetPositionInfo', {'InstanceID': '0'});
      _failures = 0;
      final state = switch (_tag(t, 'CurrentTransportState')) {
        'PLAYING' => 'PLAYING',
        'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => 'PAUSED',
        'TRANSITIONING' => 'BUFFERING',
        _ => 'IDLE',
      };
      final finished = state == 'IDLE' && _last == 'PLAYING';
      _last = state;
      status.add(CastMediaStatus(state, parseUpnpTime(_tag(p, 'RelTime')), idleReason: finished ? 'FINISHED' : null));
    } catch (_) {
      if (++_failures >= 5) await close(stopApp: false); // switched off or gone from the network
    }
  }

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
    _quiet(() => _call(_avTransport, 'Stop', {'InstanceID': '0'}));
    await _call(_avTransport, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': url,
      'CurrentURIMetaData': didl(url, contentType, title, artist, album, image),
    });
    if (play) await _call(_avTransport, 'Play', {'InstanceID': '0', 'Speed': '1'});
    if (position > const Duration(seconds: 2)) {
      // many renderers only seek once they're playing
      await Future.delayed(const Duration(milliseconds: 800));
      seek(position);
    }
  }

  @override
  void play() => _quiet(() => _call(_avTransport, 'Play', {'InstanceID': '0', 'Speed': '1'}));
  @override
  void pause() => _quiet(() => _call(_avTransport, 'Pause', {'InstanceID': '0'}));
  @override
  void seek(Duration to) =>
      _quiet(() => _call(_avTransport, 'Seek', {'InstanceID': '0', 'Unit': 'REL_TIME', 'Target': upnpTime(to)}));

  @override
  void setVolume(double level) {
    volume = level.clamp(0, 1).toDouble();
    _quiet(() => _call(_rendering, 'SetVolume',
        {'InstanceID': '0', 'Channel': 'Master', 'DesiredVolume': '${(volume * 100).round()}'}));
  }

  @override
  Future<void> close({bool stopApp = true}) async {
    if (!isOpen) return;
    _poll?.cancel();
    if (stopApp) {
      try {
        await _call(_avTransport, 'Stop', {'InstanceID': '0'});
      } catch (_) {}
    }
    closed.complete();
    await status.close();
  }
}

/// Every speaker Encore can play on: Google Cast and UPnP / DLNA, looked for at the same time. A device that
/// does both shows once, as Cast (it plays more formats there).
Future<List<CastDevice>> findSpeakers() async {
  final r = await Future.wait([findCastDevices(), findUpnpRenderers()]);
  final cast = r[0], hosts = {for (final d in cast) d.host};
  return [...cast, ...r[1].where((d) => !hosts.contains(d.host))];
}
