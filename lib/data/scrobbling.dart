/// Scrobbling to your own ListenBrainz and Last.fm, through the server (Conductor's `encore.scrobbling`): each
/// person links their own accounts, and the server sends their plays there.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';
import 'library.dart';
import 'subsonic.dart';

class ScrobbleAccount {
  final bool linked;
  final String name;

  /// The server's own settings link it (the server owner's ListenBrainz): it can't be changed from here.
  final bool fromSettings;

  /// The service stopped accepting it: link it again.
  final bool broken;

  /// Last.fm only: the server has what linking needs (its API key and secret).
  final bool available;

  const ScrobbleAccount({this.linked = false, this.name = '', this.fromSettings = false, this.broken = false, this.available = true});

  factory ScrobbleAccount.fromJson(Map<String, dynamic> j) => ScrobbleAccount(
    linked: j['linked'] == true,
    name: (j['name'] ?? '').toString(),
    fromSettings: j['fromSettings'] == true,
    broken: j['broken'] == true,
    available: j['available'] != false,
  );
}

class Scrobbling {
  final bool supported;
  final ScrobbleAccount listenBrainz;
  final ScrobbleAccount lastfm;
  const Scrobbling({this.supported = true, this.listenBrainz = const ScrobbleAccount(), this.lastfm = const ScrobbleAccount()});

  factory Scrobbling.fromResponse(Map<String, dynamic> r) {
    final s = (r['scrobbling'] as Map?)?.cast<String, dynamic>() ?? const {};
    Map<String, dynamic> m(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};
    return Scrobbling(
      listenBrainz: ScrobbleAccount.fromJson(m(s['listenbrainz'])),
      lastfm: ScrobbleAccount.fromJson(m(s['lastfm'])),
    );
  }
}

/// Where Last.fm's approval page is, and the token to finish the link with.
class LastfmLink {
  final String url;
  final String token;
  const LastfmLink(this.url, this.token);
}

extension ScrobblingCalls on SubsonicClient {
  Future<Scrobbling> scrobbling() async => Scrobbling.fromResponse(await call('getScrobbling'));

  /// Links ListenBrainz with the user token from listenbrainz.org/settings (the server checks it); empty unlinks.
  Future<Scrobbling> setListenBrainz(String token) async =>
      Scrobbling.fromResponse(await callPost('setListenBrainz', {'token': token.trim()}));

  Future<LastfmLink> lastfmLinkStart() async {
    final r = await call('lastfmLinkStart');
    final l = (r['lastfmLink'] as Map?)?.cast<String, dynamic>() ?? const {};
    return LastfmLink((l['url'] ?? '').toString(), (l['token'] ?? '').toString());
  }

  /// 'waiting' (not approved on Last.fm yet), 'linked' or 'expired'.
  Future<String> lastfmLinkFinish(String token) async {
    final r = await callPost('lastfmLinkFinish', {'token': token});
    return ((r['lastfmLink'] as Map?)?['status'] ?? 'expired').toString();
  }

  Future<Scrobbling> lastfmUnlink() async => Scrobbling.fromResponse(await call('lastfmUnlink'));
}

final scrobblingProvider = FutureProvider.autoDispose<Scrobbling>((ref) async {
  ref.cacheFor(const Duration(minutes: 10));
  final c = ref.watch(clientProvider);
  if (c == null) return const Scrobbling(supported: false);
  try {
    return await c.scrobbling();
  } on SubsonicException catch (e) {
    // a server without it (Navidrome, an older Conductor) doesn't know the call
    if (e.code == 70 || e.message.contains(' 404')) return const Scrobbling(supported: false);
    rethrow;
  }
});
