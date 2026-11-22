import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/settings.dart' show prefs;
import 'account.dart';
import 'library.dart' show onWifiProvider, connectivityProvider;
import 'subsonic.dart';

/// The server's address on your home network (optional, one per server), e.g.
/// https://lan-music.example.com:4541. On the same Wi-Fi as the server, Encore talks to it there: straight
/// across the network, no VPN or internet needed. Away from home it uses the main address as usual.
class LocalAddressNotifier extends Notifier<String> {
  static const key = 'localAddress'; // per server (account.dart swaps it with the server)

  @override
  String build() {
    ref.watch(accountProvider);
    return prefs.getString(key) ?? '';
  }

  Future<void> set(String address) async {
    final a = address.trim().replaceAll(RegExp(r'/+$'), '');
    if (a.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, a);
    }
    state = a;
  }
}

final localAddressProvider = NotifierProvider<LocalAddressNotifier, String>(LocalAddressNotifier.new);

/// True while the server answers at its home-network address. Checked every 30 s on Wi-Fi or Ethernet, when
/// the network changes and when the app comes back; one unanswered check while it was answering isn't
/// enough to switch away (the network may just be busy).
class LocalLinkNotifier extends Notifier<bool> {
  Timer? _timer;
  bool _checking = false;
  int _misses = 0;
  int _gen = 0; // goes up with each build: a check started for another server or network is dropped

  @override
  bool build() {
    ref.watch(accountProvider);
    final address = ref.watch(localAddressProvider);
    final onWifi = ref.watch(onWifiProvider);
    ref.watch(connectivityProvider); // a different network: look again
    _gen++;
    _checking = false;
    _misses = 0;
    _timer?.cancel();
    ref.onDispose(() => _timer?.cancel());
    if (address.isEmpty || !onWifi) return false;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => check());
    Future.microtask(check);
    return false;
  }

  /// Does the server answer at [address] with this login? (for checking an address before saving it)
  static Future<bool> answers(Credentials creds, String address) async {
    final c = SubsonicClient(creds, via: address.trim().replaceAll(RegExp(r'/+$'), ''));
    try {
      final r = await http.get(c.url('ping')).timeout(const Duration(seconds: 3));
      return r.statusCode == 200 && r.body.contains('"ok"');
    } catch (_) {
      return false;
    } finally {
      c.close();
    }
  }

  Future<void> check() async {
    final creds = ref.read(accountProvider).value;
    final address = ref.read(localAddressProvider);
    if (creds == null || address.isEmpty || _checking) return;
    _checking = true;
    final gen = _gen;
    final ok = ref.read(onWifiProvider) && await answers(creds, address);
    if (gen != _gen) return; // the server or the network changed meanwhile: this answer is for the old one
    _checking = false;
    _misses = ok ? 0 : _misses + 1;
    final now = ok || (state && _misses < 2);
    if (now != state) state = now;
  }
}

final localLinkProvider = NotifierProvider<LocalLinkNotifier, bool>(LocalLinkNotifier.new);
