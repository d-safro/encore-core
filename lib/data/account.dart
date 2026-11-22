import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/settings.dart';
import 'db.dart';
import 'jam.dart';
import 'library_pins.dart';
import 'library.dart';
import 'subsonic.dart';
import 'local_link.dart';
import 'usb_link.dart';

const _storage = FlutterSecureStorage();

/// A server you've signed in to. Each has its own copy of the library (and list of downloads) on the phone.
class SavedAccount {
  const SavedAccount(this.server, this.user, this.pass, this.db);
  final String server, user, pass, db; // db: the phone's library file for this server
  String get id => md5.convert(utf8.encode('$server|$user')).toString().substring(0, 10);
  Credentials get creds => Credentials(server, user, pass);
  Map<String, String> toJson() => {'server': server, 'user': user, 'pass': pass, 'db': db};
  static SavedAccount fromJson(Map j) =>
      SavedAccount('${j['server']}', '${j['user']}', '${j['pass']}', '${j['db'] ?? 'encore.db'}');
}

/// Every saved server (the first one ever used keeps the original library file).
Future<List<SavedAccount>> savedAccounts() async {
  try {
    final raw = await _storage.read(key: 'accounts');
    if (raw != null) return [for (final j in jsonDecode(raw) as List) SavedAccount.fromJson(j as Map)];
  } catch (_) {}
  final server = await _storage.read(key: 'server');
  final user = await _storage.read(key: 'user');
  final pass = await _storage.read(key: 'pass');
  if (server == null || user == null || pass == null) return [];
  return [SavedAccount(server, user, pass, 'encore.db')];
}

Future<void> _saveAccounts(List<SavedAccount> all) =>
    _storage.write(key: 'accounts', value: jsonEncode([for (final a in all) a.toJson()]));

/// The library file of the server in use (main() opens it before anything else).
Future<String> currentDbFile() async {
  final server = await _storage.read(key: 'server');
  final user = await _storage.read(key: 'user');
  for (final a in await savedAccounts()) {
    if (a.server == server && a.user == user) return a.db;
  }
  return 'encore.db';
}

/// Settings that belong to one server (its queue, pins, searches, podcasts seen…): put aside when you switch
/// to another server, and brought back when you switch back.
const _perServerKeys = {
  'queue', 'downloadPins', 'downloadQueue', 'localAddress', 'libraryPins', 'manualDownloads', 'pendingScrobbles', 'podcastSeen', 'recentSearch',
  'searchHistory', 'smartShuffle', 'smartShuffleHidden', 'lyricsPicks', 'radioArt', 'jamUrl', 'jamToken', 'podcastDone',
  'playlistCovers', 'followedArtists', 'releaseCache', 'releaseSeen', 'showsCache', 'showsPrefs',
};
bool _perServer(String k) =>
    !k.contains('@') &&
    (_perServerKeys.contains(k) ||
        k.startsWith('shown:') ||
        k.startsWith('podcastCache') ||
        k.startsWith('syncLast:') || // what was last agreed with that server's sync (data/sync.dart)
        k.startsWith('syncAt:'));

Future<void> _swapPrefs(String fromId, String toId) async {
  for (final k in prefs.getKeys().where(_perServer).toList()) {
    await _put('$k@$fromId', prefs.get(k));
    await prefs.remove(k);
  }
  final suffix = '@$toId';
  for (final k in prefs.getKeys().where((k) => k.endsWith(suffix)).toList()) {
    await _put(k.substring(0, k.length - suffix.length), prefs.get(k));
    await prefs.remove(k);
  }
}

/// Signed out of the last server: what belonged to it goes (its queue, home-network address, scrobbles
/// waiting to be sent, Jam…), so the next server you sign in to doesn't start with them.
Future<void> forgetServerPrefs() async {
  for (final k in prefs.getKeys().where(_perServer).toList()) {
    await prefs.remove(k);
  }
}

Future<void> _put(String k, Object? v) async {
  switch (v) {
    case String s:
      await prefs.setString(k, s);
    case bool b:
      await prefs.setBool(k, b);
    case int i:
      await prefs.setInt(k, i);
    case double d:
      await prefs.setDouble(k, d);
    case List l:
      await prefs.setStringList(k, l.map((e) => '$e').toList());
  }
}

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

  /// Checks the login with the server first; throws a readable error if it fails. Signing in while
  /// already signed in adds the server and switches to it (the other one stays saved).
  Future<void> signIn(String server, String user, String pass, {Future<void> Function()? beforeSwitch}) async {
    var s = server.trim();
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
    final creds = Credentials(s, user.trim(), pass);
    final c = SubsonicClient(creds);
    try {
      await c.ping();
    } finally {
      c.close();
    }
    final all = await savedAccounts();
    final current = state.value;
    final existing = all.where((a) => a.server == creds.base && a.user == creds.username).firstOrNull;
    var acct = SavedAccount(creds.base, creds.username, pass, existing?.db ?? (all.isEmpty ? 'encore.db' : ''));
    if (acct.db.isEmpty) acct = SavedAccount(acct.server, acct.user, pass, 'encore-${acct.id}.db');
    await _saveAccounts([...all.where((a) => a.id != acct.id), acct]);
    if (current == null) {
      if (libraryDb.file != acct.db) {
        final old = libraryDb;
        libraryDb = await LibraryDb.open(file: acct.db);
        await old.close();
        ref.invalidate(dbProvider);
        ref.invalidate(downloadsProvider);
      }
      await _makeCurrent(acct);
      Future.microtask(() => ref.read(syncProvider.notifier).sync()); // build the offline copy in the background
    } else {
      await switchTo(acct, beforeSwitch: beforeSwitch);
    }
  }

  Future<void> _makeCurrent(SavedAccount a) async {
    await _storage.write(key: 'server', value: a.server);
    await _storage.write(key: 'user', value: a.user);
    await _storage.write(key: 'pass', value: a.pass);
    state = AsyncData(a.creds);
  }

  /// Use another saved server: its own library copy, downloads, queue and pins come back.
  /// [beforeSwitch] stops playback first (the player lives in the UI layer).
  Future<void> switchTo(SavedAccount a, {Future<void> Function()? beforeSwitch}) async {
    final cur = state.value;
    if (cur != null && cur.base == a.server && cur.username == a.user) return;
    await beforeSwitch?.call();
    final from = (await savedAccounts()).where((x) => cur != null && x.server == cur.base && x.user == cur.username);
    if (from.isNotEmpty) await _swapPrefs(from.first.id, a.id);
    final old = libraryDb;
    libraryDb = await LibraryDb.open(file: a.db);
    await old.close();
    ref.invalidate(dbProvider);
    ref.invalidate(downloadsProvider);
    // things read from this server's settings when they started
    ref.invalidate(libraryPinsProvider);
    ref.invalidate(heartsProvider);
    ref.invalidate(syncProvider);
    ref.invalidate(serverReachableProvider);
    ref.invalidate(jamProvider);
    await _makeCurrent(a);
    if (await libraryDb.lastSync() == null) {
      Future.microtask(() => ref.read(syncProvider.notifier).sync());
    }
  }

  /// Signs out of this server. Another saved one, if any, takes its place.
  Future<void> signOut({Future<void> Function()? beforeSwitch}) async {
    final cur = state.value;
    final all = await savedAccounts();
    final rest = all.where((a) => cur == null || !(a.server == cur.base && a.user == cur.username)).toList();
    await _saveAccounts(rest);
    if (rest.isNotEmpty) {
      await switchTo(rest.first, beforeSwitch: beforeSwitch);
      return;
    }
    await beforeSwitch?.call();
    await _storage.deleteAll();
    await ref.read(dbProvider).clearLibrary();
    await forgetServerPrefs();
    state = const AsyncData(null);
  }
}

final accountProvider = AsyncNotifierProvider<AccountNotifier, Credentials?>(AccountNotifier.new);

final clientProvider = Provider<SubsonicClient?>((ref) {
  final creds = ref.watch(accountProvider).value;
  if (creds == null) return null;
  // the quickest way there: a USB cable to the server's computer, else its address on the home network,
  // else the main address (neither of the first two needs Wi-Fi internet or a VPN)
  final wired = ref.watch(usbLinkProvider);
  final home = !wired && ref.watch(localLinkProvider);
  final c = SubsonicClient(
    creds,
    via: wired ? UsbLinkNotifier.cableBase(creds) : (home ? ref.watch(localAddressProvider) : null),
  );
  ref.onDispose(c.close);
  return c;
});
