import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/platform.dart';
import 'account.dart';
import 'subsonic.dart';

/// Music over a USB cable. With the phone plugged into the computer that runs the server, and `encore-usb`
/// running there (tools/encore-usb.sh: it asks adb to forward the phone's port 4533 to the computer's),
/// the server answers on the phone's own 127.0.0.1:4533. Then everything goes through the cable (browsing,
/// playing, downloads: see clientProvider): fast, and no Wi-Fi, internet or VPN needed.
///
/// True while the server answers through the cable. Checked every 10 s (it's the phone talking to itself:
/// nothing leaves the phone when no cable is in), when the app comes back, and when the server changes.
class UsbLinkNotifier extends Notifier<bool> {
  static const port = 4533;
  Timer? _timer;
  bool _checking = false;
  int _misses = 0; // checks in a row the cable didn't answer

  /// [u] taken through the cable (same path and login, so a server under e.g. /navidrome works too).
  static Uri viaCable(Uri u) => u.replace(scheme: 'http', host: '127.0.0.1', port: port);

  /// The server's address through the cable.
  static String cableBase(Credentials c) => viaCable(Uri.parse(c.base)).toString().replaceAll(RegExp(r'/+$'), '');

  @override
  bool build() {
    // the desktop is never "the phone on a cable": its own 127.0.0.1:4533 may be the server itself, without
    // the extras (Settings › Server › Address on your home network covers that computer, see README)
    if (isDesktop) return false;
    ref.watch(accountProvider); // not clientProvider: that one follows this
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => check());
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(check);
    return false;
  }

  Future<void> check() async {
    if (isDesktop) return;
    final creds = ref.read(accountProvider).value;
    if (creds == null || _checking) return;
    _checking = true;
    var ok = false;
    final c = SubsonicClient(creds, via: cableBase(creds));
    try {
      final r = await http.get(c.url('ping')).timeout(const Duration(seconds: 3));
      ok = r.statusCode == 200 && r.body.contains('"ok"');
    } catch (_) {} finally {
      c.close();
    }
    _checking = false;
    // unplugged = two checks in a row without an answer (one slow answer while the cable is busy isn't)
    _misses = ok ? 0 : _misses + 1;
    final now = ok || (state && _misses < 2);
    if (now != state) state = now;
  }
}

final usbLinkProvider = NotifierProvider<UsbLinkNotifier, bool>(UsbLinkNotifier.new);
