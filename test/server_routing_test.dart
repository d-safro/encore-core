import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:encore/core/settings.dart';
import 'package:encore/data/account.dart';
import 'package:encore/data/library.dart';
import 'package:encore/data/local_link.dart';
import 'package:encore/data/subsonic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _a = Credentials('https://a.test', 'me', 'pw');
const _b = Credentials('https://b.test', 'me', 'pw');

class _Account extends AccountNotifier {
  @override
  Future<Credentials?> build() async => _a;
  void use(Credentials c) => state = AsyncData(c);
}

void main() {
  test("an answer from the last server's home address doesn't route the new server there", () async {
    // server A's home-network address answers, slowly
    final home = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => home.close(force: true));
    final answering = Completer<void>(), answer = Completer<void>();
    home.listen((req) async {
      answering.complete();
      await answer.future;
      req.response.write('{"subsonic-response":{"status":"ok"}}');
      await req.response.close();
    });
    SharedPreferences.setMockInitialValues({'localAddress': 'http://127.0.0.1:${home.port}'});
    prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      accountProvider.overrideWith(_Account.new),
      connectivityProvider.overrideWith((ref) => Stream.value([ConnectivityResult.wifi])),
    ]);
    addTearDown(c.dispose);
    await c.read(accountProvider.future);
    c.listen(clientProvider, (_, _) {});
    await c.read(connectivityProvider.future);
    expect(c.read(localLinkProvider), isFalse);
    await answering.future; // A's check is under way
    // switched to server B, which has no home-network address (account.dart swaps the pref)
    await prefs.remove('localAddress');
    (c.read(accountProvider.notifier) as _Account).use(_b);
    c.read(localAddressProvider);
    expect(c.read(localLinkProvider), isFalse);
    answer.complete(); // A answers
    await Future.delayed(const Duration(milliseconds: 200));
    expect(c.read(localLinkProvider), isFalse);
    expect(c.read(clientProvider)!.base, 'https://b.test'); // B's main address, not A's home one or nowhere
  });

  test("signing out of the last server forgets its home address, queue and scrobbles", () async {
    SharedPreferences.setMockInitialValues({
      'localAddress': 'http://192.0.2.1:4533',
      'queue': '{}',
      'pendingScrobbles': ['s1|1'],
      'jamUrl': 'x',
      'shown:hint': true,
      'settings': '{}',
    });
    prefs = await SharedPreferences.getInstance();
    await forgetServerPrefs();
    expect(prefs.getKeys(), {'settings'}); // app settings stay; the server's own things go
  });
}
