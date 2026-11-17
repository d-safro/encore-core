import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'account.dart';

/// Music over a USB cable. With the phone plugged into the computer that runs the server, and `encore-usb`
/// running there (tools/encore-usb.sh: it asks adb to forward the phone's port 4533 to the computer's),
/// the server answers on the phone's own 127.0.0.1:4533. Downloads then go through the cable: fast, and no
/// Wi-Fi, internet or Tailscale needed.
///
/// True while the server answers through the cable. Checked every 10 s (it's the phone talking to itself:
/// nothing leaves the phone when no cable is in), when the app comes back, and when the server changes.
class UsbLinkNotifier extends Notifier<bool> {
  static const port = 4533;
  Timer? _timer;
  bool _checking = false;

  /// [u] taken through the cable (same path and login, so a server under e.g. /navidrome works too).
  static Uri viaCable(Uri u) => u.replace(scheme: 'http', host: '127.0.0.1', port: port);

  @override
  bool build() {
    ref.watch(clientProvider);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => check());
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(check);
    return false;
  }

  Future<void> check() async {
    final c = ref.read(clientProvider);
    if (c == null || _checking) return;
    _checking = true;
    var ok = false;
    try {
      final r = await http.get(viaCable(c.url('ping'))).timeout(const Duration(seconds: 3));
      ok = r.statusCode == 200 && r.body.contains('"ok"');
    } catch (_) {}
    _checking = false;
    if (ok != state) state = ok;
  }
}

final usbLinkProvider = NotifierProvider<UsbLinkNotifier, bool>(UsbLinkNotifier.new);
