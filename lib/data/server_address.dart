import 'subsonic.dart';

/// An address as typed: https:// when it says neither, and no slash at the end.
String normalizeServerAddress(String address) {
  var s = address.trim();
  if (s.isEmpty) return s;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
  return s.replaceAll(RegExp(r'/+$'), '');
}

/// Why a new address for the server can't be used. Nothing was changed.
enum AddressProblem {
  /// Empty, or not a web address.
  notAnAddress,

  /// It's the address in use already.
  same,

  /// Encore has that address saved as a server of its own already.
  alreadySaved,

  /// Nothing answers there (or not in time, or the secure connection failed).
  noAnswer,

  /// Something answers, but not a Subsonic server.
  notAServer,

  /// The server there doesn't take the saved login.
  loginRefused,

  /// A server answers with the saved login, but not the same one.
  otherServer,
}

class AddressRefused implements Exception {
  const AddressRefused(this.problem, this.message);
  final AddressProblem problem;
  final String message;
  @override
  String toString() => message;
}

/// How [checkNewAddress] talks to a server: a client for [creds] whose requests go to [at].
typedef ConnectTo = SubsonicClient Function(Credentials creds, String at);

SubsonicClient _connect(Credentials creds, String at) => SubsonicClient(creds, via: at);

/// OpenSubsonic's codes for a login that isn't taken: wrong user or password, token login not allowed, and
/// the like.
const _loginCodes = {40, 41, 42, 43, 44};

/// Checks that [newBase] is another address of the same server [creds] signs in to, with the same login.
/// Throws [AddressRefused] saying why not.
///
/// The same login must be taken there. Then, as far as can be told without the server naming itself:
/// - when the address in use answers too, both must say they're the same kind of server, at the same version
///   (OpenSubsonic's `type` and `serverVersion`);
/// - songs this device has from the server ([knownSongs]: downloads, the library copy) must be there: when
///   none of them is, it's another server; with none to ask about and the old address answering, their
///   newest albums must have something in common.
///
/// [reachedAt]: where the address in use is reached now (its home-network address, a USB cable...).
/// The password is only ever sent the usual way (a salted token), and never appears in a message.
Future<void> checkNewAddress(
  Credentials creds,
  String newBase, {
  String? reachedAt,
  List<String> knownSongs = const [],
  ConnectTo connect = _connect,
  Duration oldTimeout = const Duration(seconds: 8),
}) async {
  final uri = Uri.tryParse(newBase);
  if (newBase.isEmpty || uri == null || !uri.hasAuthority || uri.host.isEmpty) {
    throw const AddressRefused(AddressProblem.notAnAddress, 'That isn\'t a web address, e.g. https://music.example.com');
  }
  if (newBase == creds.base) {
    throw const AddressRefused(AddressProblem.same, 'That\'s the address Encore uses already');
  }
  final there = connect(Credentials(newBase, creds.username, creds.password), newBase);
  final here = connect(creds, reachedAt ?? creds.base);
  try {
    final Map<String, dynamic> pong;
    try {
      pong = await there.ping();
    } on SubsonicException catch (e) {
      if (_loginCodes.contains(e.code)) {
        throw AddressRefused(
          AddressProblem.loginRefused,
          'The server there doesn\'t take your login as ${creds.username} ($e). '
          'It may be another server, or your password changed: sign in again first.',
        );
      }
      if (e.code == 0 && e.message.contains('doesn\'t answer like')) {
        throw const AddressRefused(
          AddressProblem.notAServer,
          'Something answers there, but not a music server. Check the address (and its port).',
        );
      }
      throw AddressRefused(AddressProblem.notAServer, 'The server there said: $e');
    } catch (e) {
      // can't be reached, didn't answer in time, the secure connection failed...
      throw AddressRefused(AddressProblem.noAnswer, 'Nothing answers there. ${friendlyError(e)}');
    }

    // the address in use, if it answers from here
    Map<String, dynamic>? before;
    try {
      before = await here.ping().timeout(oldTimeout);
    } catch (_) {}
    if (before != null) {
      for (final k in const ['type', 'serverVersion']) {
        final a = before[k], b = pong[k];
        if (a != null && b != null && '$a' != '$b') {
          throw AddressRefused(
            AddressProblem.otherServer,
            'That\'s another server: it says it\'s ${_name(pong)}, the one you use says ${_name(before)}',
          );
        }
      }
    }

    if (knownSongs.isNotEmpty) {
      var found = 0, missing = 0;
      for (final id in knownSongs) {
        try {
          await there.song(id);
          found++;
        } on SubsonicException catch (e) {
          if (e.code == 70) missing++; // not found
        } catch (_) {}
        if (found > 0) break;
      }
      if (found == 0 && missing > 0) {
        throw const AddressRefused(
          AddressProblem.otherServer,
          'That\'s another server: it doesn\'t have the songs Encore has from yours',
        );
      }
    } else if (before != null) {
      Future<Set<String>> albums(SubsonicClient c) async =>
          {for (final a in await c.albumList('newest', size: 20)) a.id};
      try {
        final a = await albums(here), b = await albums(there);
        if (a.isNotEmpty && b.isNotEmpty && a.intersection(b).isEmpty) {
          throw const AddressRefused(
            AddressProblem.otherServer,
            'That\'s another server: its albums aren\'t the ones on yours',
          );
        }
      } on AddressRefused {
        rethrow;
      } catch (_) {}
    }
  } finally {
    there.close();
    here.close();
  }
}

String _name(Map<String, dynamic> pong) {
  final type = pong['type'], version = pong['serverVersion'];
  if (type == null && version == null) return 'a Subsonic server';
  return [?type?.toString(), ?version?.toString()].join(' ');
}
