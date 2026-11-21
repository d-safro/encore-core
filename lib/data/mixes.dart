import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account.dart';
import 'library.dart';
import 'subsonic.dart';

/// Your mixes: Discover Weekly, Release Radar, Daily Mix 1–6 and the Daylist. The server (music-lookup's
/// mixes.py) makes them as real playlists, so every app has them; Encore shows them in a row on Home and turns
/// each kind on or off in Settings.
class MixKind {
  const MixKind(this.kind, this.name, {this.enabled = true, this.updated});
  final String kind, name; // discover · radar · daily · daylist
  final bool enabled;
  final DateTime? updated;

  factory MixKind.fromJson(Map<String, dynamic> j) => MixKind(
    '${j['kind'] ?? ''}',
    '${j['name'] ?? ''}',
    enabled: j['enabled'] != false,
    updated: (j['updated'] is num && j['updated'] > 0) ? DateTime.fromMillisecondsSinceEpoch(j['updated']) : null,
  );
}

class Mix {
  const Mix(this.kind, this.playlistId, this.name, {this.comment = '', this.songCount = 0});
  final String kind, playlistId, name, comment;
  final int songCount;

  factory Mix.fromJson(Map<String, dynamic> j) => Mix(
    '${j['kind'] ?? ''}',
    '${j['playlistId'] ?? ''}',
    '${j['name'] ?? ''}',
    comment: '${j['comment'] ?? ''}',
    songCount: (j['songCount'] as num?)?.toInt() ?? 0,
  );
}

class Mixes {
  const Mixes({this.kinds = const [], this.mixes = const [], this.supported = true});
  final List<MixKind> kinds;
  final List<Mix> mixes;
  final bool supported; // false: the server has no mixes (Navidrome without music-lookup)

  factory Mixes.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> l(dynamic v) => [for (final x in (v as List? ?? const [])) if (x is Map) x.cast<String, dynamic>()];
    return Mixes(
      kinds: l(j['kind']).map(MixKind.fromJson).toList(),
      mixes: l(j['mix']).map(Mix.fromJson).where((m) => m.playlistId.isNotEmpty).toList(),
    );
  }

  bool isOn(String kind) => kinds.where((k) => k.kind == kind).firstOrNull?.enabled ?? true;
}

/// What each kind is, for Settings.
const mixAbout = {
  'discover': 'Every Monday: 30 songs you don\'t have yet, fetched for a week. Heart one to keep it',
  'radar': 'Every Friday: new releases from artists you follow and play most',
  'daily': 'Every day: up to 6 mixes of your library around your top artists, with some songs new to you',
  'daylist': 'Through the day: what you play at this time of day, and songs like it',
};

const mixNames = {'discover': 'Discover Weekly', 'radar': 'Release Radar', 'daily': 'Daily mixes', 'daylist': 'Daylist'};

final mixesProvider = FutureProvider.autoDispose<Mixes>((ref) async {
  ref.cacheFor(const Duration(minutes: 10));
  final c = ref.watch(clientProvider);
  if (c == null) return const Mixes(supported: false);
  try {
    return await c.mixes();
  } on SubsonicException catch (e) {
    if (e.code == 70 || e.message.contains(' 404')) return const Mixes(supported: false);
    rethrow;
  }
});

/// Turn a kind of mix on (it's made straight away) or off (its playlists are deleted).
Future<void> setMixOn(WidgetRef ref, String kind, bool on) async {
  await ref.read(clientProvider)?.setMix(kind, on);
  ref.invalidate(mixesProvider);
}
