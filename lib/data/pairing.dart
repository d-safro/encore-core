import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'devices.dart';
import 'subsonic.dart';

/// Sign in with your phone: the new device (not signed in yet) asks the server for a 6-digit code and shows
/// it; on a device that is signed in you type the code, and it hands over the server address and login.
/// Needs the server extras (music-lookup's devices.py). A code lasts 5 minutes and works once.

/// What the new device gets.
class PairedLogin {
  const PairedLogin(this.server, this.user, this.pass, this.localAddress);
  final String server, user, pass, localAddress;
}

class PairingCode {
  const PairingCode(this.code, this.token, this.expires);
  final String code, token;
  final Duration expires;

  /// 123 456, easier to read out and type.
  String get pretty => code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
}

/// The address as typed, made into a server base (https:// when no scheme is given).
String serverBase(String typed) {
  var s = typed.trim().replaceAll(RegExp(r'/+$'), '');
  if (s.isEmpty) return s;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
  return s;
}

const _noExtras = "This server can't do phone sign-in (it needs Conductor or music-lookup). Sign in with your password.";

http.Client _http() => IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 10));

Future<Map<String, dynamic>> _open(String base, String view, Map<String, String> q, Duration timeout) async {
  final c = _http();
  try {
    final u = Uri.parse('$base/rest/$view').replace(queryParameters: {...q, 'f': 'json', 'v': '1.16.1', 'c': defaultClientName});
    final res = await c.get(u).timeout(timeout);
    if (res.statusCode == 404 || res.statusCode == 501) throw SubsonicException(0, _noExtras); // plain Navidrome
    if (res.statusCode != 200) throw SubsonicException(0, 'Server answered ${res.statusCode}');
    Map<String, dynamic>? r;
    try {
      r = ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['subsonic-response'] as Map).cast<String, dynamic>();
    } catch (_) {}
    if (r == null) throw SubsonicException(0, "That address doesn't answer like a Navidrome / Subsonic server");
    if (r['status'] != 'ok') {
      final e = (r['error'] as Map?) ?? const {};
      final code = (e['code'] as num?)?.toInt() ?? 0;
      throw SubsonicException(code, '${e['message'] ?? 'Request failed'}');
    }
    return r;
  } on TimeoutException {
    throw SubsonicException(0, "The server didn't answer. Check the address.");
  } on SocketException {
    throw SubsonicException(0, "Can't reach that address. Check it, and that you're connected (VPN, Tailscale…).");
  } finally {
    c.close();
  }
}

/// New device: ask the server at [server] for a code.
Future<PairingCode> startPairing(String server) async {
  final r = await _open(serverBase(server), 'pairStart', {'name': deviceName()}, const Duration(seconds: 15));
  final p = (r['pair'] as Map?)?.cast<String, dynamic>();
  if (p == null || p['code'] == null) {
    throw SubsonicException(0, _noExtras);
  }
  return PairingCode('${p['code']}', '${p['token']}', Duration(seconds: (p['expires'] as num?)?.toInt() ?? 300));
}

/// New device: waits (a long poll at a time) until the code was typed on the other device. null when it ran out.
/// [cancelled] stops it early.
Future<PairedLogin?> waitForLogin(String server, PairingCode code, {bool Function()? cancelled}) async {
  final end = DateTime.now().add(code.expires + const Duration(seconds: 5));
  while (DateTime.now().isBefore(end) && !(cancelled?.call() ?? false)) {
    try {
      final r = await _open(serverBase(server), 'pairPoll', {'token': code.token, 'wait': '20'}, const Duration(seconds: 30));
      final p = (r['pair'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (p['status'] == 'done') {
        final l = (p['login'] as Map?)?.cast<String, dynamic>() ?? const {};
        return PairedLogin('${l['server'] ?? ''}', '${l['user'] ?? ''}', '${l['pass'] ?? ''}', '${l['localAddress'] ?? ''}');
      }
    } on SubsonicException catch (e) {
      if (e.code == 70) return null; // ran out
      await Future.delayed(const Duration(seconds: 3));
    }
  }
  return null;
}

/// Signed-in device: hand this login to the device showing [code]. Returns that device's name.
Future<String> approvePairing(SubsonicClient c, String code, {String localAddress = ''}) async {
  final digits = code.replaceAll(RegExp(r'\D'), '');
  if (digits.length != 6) throw SubsonicException(10, 'The code has 6 digits');
  final r = await c.call('pairApprove', {
    'code': digits,
    'login': jsonEncode({
      'server': c.creds.base,
      'user': c.creds.username,
      'pass': c.creds.password,
      'localAddress': localAddress,
    }),
  });
  return '${(r['pair'] as Map?)?['name'] ?? 'the other device'}';
}
