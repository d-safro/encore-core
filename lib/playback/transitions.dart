import 'dart:convert';

import '../core/settings.dart';

/// Edit transitions (a playlist's menu): how one song goes into the next in that playlist, chosen by hand:
/// Smart (Automix), Fade (the crossfade), Cut (no blend: gapless). Kept in the pref `playlistTransitions`
/// (`{playlist id: {"songA>songB": kind}}`) and synced to your other devices; used whenever the playlist plays
/// in that order. Pairs not chosen follow Settings.
enum TransitionKind { smart, fade, cut }

const transitionLabels = {TransitionKind.smart: 'Smart', TransitionKind.fade: 'Fade', TransitionKind.cut: 'Cut'};

String pairKey(String a, String b) => '$a>$b';

String? _raw;
Map<String, Map<String, String>> _parsed = {};

/// Read often (the player asks several times a second): parsed again only when the pref changed.
Map<String, Map<String, String>> readTransitions() {
  final raw = prefs.getString('playlistTransitions') ?? '{}';
  if (raw == _raw) return _parsed;
  _raw = raw;
  return _parsed = _parse(raw);
}

Map<String, Map<String, String>> _parse(String raw) {
  try {
    final j = jsonDecode(raw) as Map;
    return {
      for (final e in j.entries)
        if (e.value is Map) '${e.key}': {for (final x in (e.value as Map).entries) '${x.key}': '${x.value}'},
    };
  } catch (_) {
    return {};
  }
}

/// The chosen transition from [a] into [b] in [playlist], or null (follow Settings).
TransitionKind? transitionFor(String? playlist, String a, String b, [Map<String, Map<String, String>>? all]) {
  if (playlist == null || playlist.isEmpty) return null;
  final v = (all ?? readTransitions())[playlist]?[pairKey(a, b)];
  return TransitionKind.values.where((k) => k.name == v).firstOrNull;
}

Future<void> setTransition(String playlist, String a, String b, TransitionKind? kind) async {
  final all = {for (final e in readTransitions().entries) e.key: {...e.value}};
  final mine = all.putIfAbsent(playlist, () => {});
  if (kind == null) {
    mine.remove(pairKey(a, b));
  } else {
    mine[pairKey(a, b)] = kind.name;
  }
  if (mine.isEmpty) all.remove(playlist);
  await prefs.setString('playlistTransitions', jsonEncode(all));
}

/// Does any pair in this playlist want Automix (so its songs get measured even with Automix off)?
bool wantsSmart(String? playlist) =>
    playlist != null && (readTransitions()[playlist]?.values.contains(TransitionKind.smart.name) ?? false);
