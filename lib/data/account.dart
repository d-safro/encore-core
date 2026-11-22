import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show PlatformException;
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

/// The password store can't be used: on Linux, no keyring service (libsecret has nothing to talk to) or a
/// locked one. Shown as it reads.
class KeyringUnavailable implements Exception {
  const KeyringUnavailable({this.locked = false});
  final bool locked;
  @override
  String toString() => locked
      ? 'Your keyring is locked: unlock it and try again'
      : 'No keyring service: install gnome-keyring or KWallet';
}

/// [PlatformException]s from the password store that mean it can't be used at all (see [KeyringUnavailable]).
bool isKeyringError(Object e) {
  if (e is! PlatformException) return false;
  final what = '${e.code} ${e.message}'.toLowerCase();
  return what.contains('secret') || what.contains('keyring') || (Platform.isLinux && e.code == 'StorageError');
}

/// Runs a password-store call, turning "no keyring" into [KeyringUnavailable].
Future<T> _secure<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on PlatformException catch (e) {
    if (!isKeyringError(e)) rethrow;
    throw KeyringUnavailable(locked: e.code == 'KeyringLocked');
  }
}

/// A password-store read where nothing can be read counts as nothing saved (e.g. no keyring service).
Future<String?> _read(String key) async {
  try {
    return await _storage.read(key: key);
  } catch (_) {
    return null;
  }
}

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
  final server = await _read('server');
  final user = await _read('user');
  final pass = await _read('pass');
  if (server == null || user == null || pass == null) return [];
  return [SavedAccount(server, user, pass, 'encore.db')];
}

Future<void> _saveAccounts(List<SavedAccount> all) =>
    _secure(() => _storage.write(key: 'accounts', value: jsonEncode([for (final a in all) a.toJson()])));

/// The library file of the server in use (main() opens it before anything else).
Future<String> currentDbFile() async {
  final server = await _read('server');
  final user = await _read('user');
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
  'playlistTransitions', // that server's playlists (and synced through it: see data/sync.dart)
};
bool _perServer(String k) =>
    !k.contains('@') &&
    (_perServerKeys.contains(k) ||
        k.startsWith('shown:') ||
        k.startsWith('podcastCache') ||
        k.startsWith('syncLast:') || // what was last agreed with that server's sync (data/sync.dart)
        k.startsWith('syncAt:') ||
        k.startsWith('syncSeen'));

/// Puts the current server's settings aside under [fromId] (null: signed out of it, so they go) and brings
/// back [toId]'s.
Future<void> _swapPrefs(String? fromId, String toId) async {
  for (final k in prefs.getKeys().where(_perServer).toList()) {
    if (fromId != null) await _put('$k@$fromId', prefs.get(k));
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
    final server = await _read('server');
    final user = await _read('user');
    final pass = await _read('pass');
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
    var acct = SavedAccount(creds.base, creds.username, pass, existing?.db ?? '');
    if (acct.db.isEmpty) acct = SavedAccount(acct.server, acct.user, pass, await _newDbFile(acct.id, all));
    await _saveAccounts([...all.where((a) => a.id != acct.id), acct]);
    if (acct.db == _mainDb) await prefs.setString(_mainDbOwner, acct.id);
    if (current != null && current.base == acct.server && current.username == acct.user) {
      // the same server again (e.g. after a password change): the client uses the new login from now on;
      // its library, queue and downloads carry on as they are
      await _remember(acct);
      state = AsyncData(acct.creds);
      return;
    }
    if (current == null) {
      await _remember(acct);
      if (libraryDb.file != acct.db) {
        final old = libraryDb;
        libraryDb = await LibraryDb.open(file: acct.db);
        await old.close();
      }
      _rebuild();
      state = AsyncData(acct.creds);
      Future.microtask(() => ref.read(syncProvider.notifier).sync()); // build the offline copy in the background
    } else {
      await switchTo(acct, beforeSwitch: beforeSwitch);
    }
  }

  /// The library file for a server signed in to for the first time (or again after signing out of it). The
  /// original one (encore.db) is the first server's and stays its own, downloads and all, after it signs
  /// out; every other server has one named after it. So no server ever opens another's downloads.
  static Future<String> _newDbFile(String id, List<SavedAccount> all) async {
    final owner = prefs.getString(_mainDbOwner);
    if (owner == id) return _mainDb;
    // nobody has it yet: a new install, or (signed out before Encore noted whose it is) one that may hold
    // another server's downloads, which this server then doesn't get
    if (owner == null && !all.any((a) => a.db == _mainDb) && !await LibraryDb.hasDownloads(_mainDb)) return _mainDb;
    return 'encore-$id.db';
  }

  /// Saves [a] as the server in use (throws [KeyringUnavailable] when the password store can't be used).
  Future<void> _remember(SavedAccount a) => _secure(() async {
    await _storage.write(key: 'server', value: a.server);
    await _storage.write(key: 'user', value: a.user);
    await _storage.write(key: 'pass', value: a.pass);
  });

  /// Use another saved server: its own library copy, downloads, queue and pins come back.
  /// [beforeSwitch] stops playback first (the player lives in the UI layer).
  Future<void> switchTo(SavedAccount a, {Future<void> Function()? beforeSwitch}) async {
    final cur = state.value;
    if (cur != null && cur.base == a.server && cur.username == a.user) return;
    await _switch(a, cur == null ? null : _idOf(cur), beforeSwitch);
  }

  static String _idOf(Credentials c) => SavedAccount(c.base, c.username, '', '').id;

  /// [fromId]: the server being left, whose settings are put aside for when you come back; null when signing
  /// out of it (they go, so the next server doesn't start with its queue, Jam, pins...).
  Future<void> _switch(SavedAccount a, String? fromId, Future<void> Function()? beforeSwitch) async {
    await _remember(a); // first: a password store that can't be used stops it before anything changed
    await beforeSwitch?.call();
    await _swapPrefs(fromId, a.id);
    final old = libraryDb;
    libraryDb = await LibraryDb.open(file: a.db);
    await old.close();
    _rebuild();
    state = AsyncData(a.creds);
    if (await libraryDb.lastSync() == null) {
      Future.microtask(() => ref.read(syncProvider.notifier).sync());
    }
  }

  /// Signs out of this server. Another saved one, if any, takes its place. Its downloads stay on the device,
  /// in its own library file, for when you sign in to it again.
  Future<void> signOut({Future<void> Function()? beforeSwitch}) async {
    final cur = state.value;
    final all = await savedAccounts();
    final rest = all.where((a) => cur == null || !(a.server == cur.base && a.user == cur.username)).toList();
    final leaving = all.where((a) => !rest.contains(a)).firstOrNull;
    if (leaving?.db == _mainDb) await prefs.setString(_mainDbOwner, leaving!.id);
    await _saveAccounts(rest);
    if (rest.isNotEmpty) {
      await _switch(rest.first, null, beforeSwitch);
      return;
    }
    await beforeSwitch?.call();
    await _secure(_storage.deleteAll);
    await ref.read(dbProvider).clearLibrary();
    await forgetServerPrefs();
    // nothing of that server's (its downloads list and queue, pins, Jam...) carries on in memory: the next
    // server signed in to starts clean
    _rebuild();
    state = const AsyncData(null);
  }

  /// After the server in use changed: what was built from its library file or settings starts again.
  void _rebuild() {
    ref.invalidate(dbProvider);
    ref.invalidate(downloadsProvider);
    ref.invalidate(libraryPinsProvider);
    ref.invalidate(heartsProvider);
    ref.invalidate(syncProvider);
    ref.invalidate(serverReachableProvider);
    ref.invalidate(jamProvider);
  }
}

const _mainDb = 'encore.db';

/// Which server the original library file (encore.db) belongs to: the file and its downloads stay its own,
/// also after it signs out, and another server gets a library file of its own (see _newDbFile).
const _mainDbOwner = 'mainLibraryOwner';

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
