import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/settings.dart';
import 'library.dart';
import 'subsonic.dart';

const _storage = FlutterSecureStorage();

/// The signed-in server. The password stays in Android's encrypted storage; requests use salted tokens.
class AccountNotifier extends AsyncNotifier<Credentials?> {
  @override
  Future<Credentials?> build() async {
    final server = await _storage.read(key: 'server');
    final user = await _storage.read(key: 'user');
    final pass = await _storage.read(key: 'pass');
    if (server == null || user == null || pass == null) return null;
    return Credentials(server, user, pass);
  }

  /// Checks the login with the server first; throws a readable error if it fails.
  Future<void> signIn(String server, String user, String pass) async {
    var s = server.trim();
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
    final creds = Credentials(s, user.trim(), pass);
    final c = SubsonicClient(creds);
    try {
      await c.ping();
    } finally {
      c.close();
    }
    await _storage.write(key: 'server', value: creds.base);
    await _storage.write(key: 'user', value: creds.username);
    await _storage.write(key: 'pass', value: pass);
    state = AsyncData(Credentials(creds.base, creds.username, pass));
    Future.microtask(() => ref.read(syncProvider.notifier).sync()); // build the offline copy in the background
  }

  Future<void> signOut() async {
    await _storage.deleteAll();
    await ref.read(dbProvider).clearLibrary();
    await prefs.remove('queue');
    state = const AsyncData(null);
  }
}

final accountProvider = AsyncNotifierProvider<AccountNotifier, Credentials?>(AccountNotifier.new);

final clientProvider = Provider<SubsonicClient?>((ref) {
  final creds = ref.watch(accountProvider).value;
  if (creds == null) return null;
  final c = SubsonicClient(creds);
  ref.onDispose(c.close);
  return c;
});
