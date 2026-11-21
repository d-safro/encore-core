import 'dart:convert';
import 'dart:io';

import 'package:encore/playback/cast.dart';
import 'package:encore/playback/upnp.dart';
import 'package:flutter_test/flutter_test.dart';

const _desc = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><device>
<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>Living room TV</friendlyName><manufacturer>Acme</manufacturer><modelName>TV 3000</modelName>
<serviceList>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/rc</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/av</controlURL></service>
</serviceList></device></root>''';

/// A pretend TV: answers SOAP like a renderer and remembers every action.
Future<(HttpServer, List<(String, String)>)> fakeRenderer() async {
  final calls = <(String, String)>[];
  var state = 'STOPPED';
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) async {
    final body = await utf8.decodeStream(req);
    final action = (req.headers.value('SOAPACTION') ?? '').split('#').last.replaceAll('"', '');
    String out = '';
    if (req.uri.path == '/desc.xml') {
      out = _desc;
    } else {
      calls.add((action, body));
      if (action == 'Play') state = 'PLAYING';
      if (action == 'Pause') state = 'PAUSED_PLAYBACK';
      if (action == 'Stop') state = 'STOPPED';
      out = switch (action) {
        'GetVolume' => '<CurrentVolume>30</CurrentVolume>',
        'GetTransportInfo' => '<CurrentTransportState>$state</CurrentTransportState>',
        'GetPositionInfo' => '<RelTime>0:01:05</RelTime>',
        _ => '',
      };
    }
    req.response.write(out);
    await req.response.close();
  });
  return (srv, calls);
}

void main() {
  test('reads SSDP answers and device descriptions', () {
    expect(ssdpLocation('HTTP/1.1 200 OK\r\nST: x\r\nLocation: http://10.0.0.5:49152/desc.xml\r\n\r\n'),
        'http://10.0.0.5:49152/desc.xml');
    expect(ssdpLocation('HTTP/1.1 200 OK\r\n\r\n'), isNull);
    final d = parseDescription(_desc, Uri.parse('http://10.0.0.5:49152/desc.xml'))!;
    expect(d.name, 'Living room TV');
    expect(d.model, 'Acme TV 3000');
    expect(d.avTransport.toString(), 'http://10.0.0.5:49152/av');
    expect(d.rendering.toString(), 'http://10.0.0.5:49152/rc');
  });

  test('times and metadata', () {
    expect(upnpTime(const Duration(minutes: 3, seconds: 25)), '0:03:25');
    expect(upnpTime(const Duration(hours: 1, seconds: 5)), '1:00:05');
    expect(parseUpnpTime('0:04:07.250'), const Duration(minutes: 4, seconds: 7));
    expect(parseUpnpTime('NOT_IMPLEMENTED'), Duration.zero);
    final m = didl('http://p/s?a=1&b=2', 'audio/flac', 'Rock & Roll', 'AC/DC', 'X', null);
    expect(m, contains('protocolInfo="http-get:*:audio/flac:*"'));
    expect(m, contains('Rock &amp; Roll'));
    expect(m, contains('http://p/s?a=1&amp;b=2'));
  });

  test('plays, pauses, seeks and sets the volume on a renderer', () async {
    final (srv, calls) = await fakeRenderer();
    addTearDown(() => srv.close(force: true));
    final dev = CastDevice('TV', '127.0.0.1', srv.port, location: 'http://127.0.0.1:${srv.port}/desc.xml');
    expect(dev.isUpnp, isTrue);
    final s = await UpnpSession.connect(dev);
    expect(s.volume, 0.3);
    final seen = <CastMediaStatus>[];
    s.status.stream.listen(seen.add);
    await s.load('http://phone:4547/k/song/1', contentType: 'audio/mpeg', title: 'Song', artist: 'A',
        position: const Duration(seconds: 65));
    await Future.delayed(const Duration(milliseconds: 1500));
    final names = calls.map((c) => c.$1).toList();
    expect(names, containsAllInOrder(['SetAVTransportURI', 'Play', 'Seek']));
    expect(calls.firstWhere((c) => c.$1 == 'Seek').$2, contains('<Target>0:01:05</Target>'));
    expect(calls.firstWhere((c) => c.$1 == 'SetAVTransportURI').$2, contains('http://phone:4547/k/song/1'));
    expect(seen.any((st) => st.state == 'PLAYING' && st.position == const Duration(minutes: 1, seconds: 5)), isTrue);
    s.setVolume(0.75);
    s.pause();
    await Future.delayed(const Duration(milliseconds: 300));
    expect(calls.firstWhere((c) => c.$1 == 'SetVolume').$2, contains('<DesiredVolume>75</DesiredVolume>'));
    expect(calls.map((c) => c.$1), contains('Pause'));
    await s.close();
    expect(s.isOpen, isFalse);
    expect(calls.last.$1, 'Stop');
  });
}
