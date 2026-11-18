import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/settings.dart';
import 'account.dart';
import 'subsonic.dart';

/// Your own playlist pictures, as this phone knows them.
///
/// The picture goes to the server when it can keep one (Navidrome's own API), and then every app shows it.
/// The phone also keeps its copy, shown right away: the server takes a moment to make the new picture
/// ready, and its cover id changes once it has. When the server can't keep pictures, the copy on the phone
/// is the only one ([phoneOnly]).
class CustomCover {
  const CustomCover({required this.path, required this.serverWas, required this.phoneOnly});

  /// The picture on the phone.
  final String path;

  /// The server's cover id for this playlist when the picture was set. Once the server answers with
  /// another one, it has the new picture and the phone's copy isn't needed.
  final String serverWas;
  final bool phoneOnly;

  Map<String, dynamic> toJson() => {'path': path, 'serverWas': serverWas, 'phoneOnly': phoneOnly};
  static CustomCover? fromJson(Object? j) => j is Map && j['path'] is String
      ? CustomCover(path: j['path'] as String, serverWas: '${j['serverWas'] ?? ''}', phoneOnly: j['phoneOnly'] == true)
      : null;
}

/// What [Cover] should draw for a playlist: the phone's copy ("file:" + its path) while the server doesn't
/// have the picture yet, or for good when it can't keep one; otherwise the server's own cover id.
String shownPlaylistCover(CustomCover? mine, String serverCover) {
  if (mine == null) return serverCover;
  // offline the playlist comes from the phone's library, without the server's cover id
  if (mine.phoneOnly || serverCover.isEmpty || serverCover == mine.serverWas) return 'file:${mine.path}';
  return serverCover;
}

/// The phone's copy isn't needed any more: the server answers with a newer cover than when it was set.
bool coverIsStale(CustomCover? mine, String serverCover) =>
    mine != null && !mine.phoneOnly && serverCover.isNotEmpty && serverCover != mine.serverWas;

/// Kept per server (`playlistCovers` is one of the per-server settings).
const _key = 'playlistCovers';

Map<String, CustomCover> decodeCovers(String? s) {
  try {
    final m = jsonDecode(s ?? '{}') as Map<String, dynamic>;
    return {
      for (final e in m.entries)
        if (CustomCover.fromJson(e.value) != null) e.key: CustomCover.fromJson(e.value)!,
    };
  } catch (_) {
    return {};
  }
}

String encodeCovers(Map<String, CustomCover> m) => jsonEncode({for (final e in m.entries) e.key: e.value.toJson()});

/// How setting a picture went, for the message under it.
enum CoverSaved { onServer, onPhone }

final playlistCoversProvider = NotifierProvider<PlaylistCovers, Map<String, CustomCover>>(PlaylistCovers.new);

class PlaylistCovers extends Notifier<Map<String, CustomCover>> {
  @override
  Map<String, CustomCover> build() {
    ref.watch(accountProvider); // another server: its own pictures
    return decodeCovers(prefs.getString(_key));
  }

  Future<void> _store(Map<String, CustomCover> m) async {
    state = m;
    await prefs.setString(_key, encodeCovers(m));
  }

  /// The cover to draw for playlist [id] whose server cover id is [serverCover].
  String shown(String id, String serverCover) => shownPlaylistCover(state[id], serverCover);

  /// Sets [jpeg] as playlist [id]'s picture: on the server when it can keep it, else on this phone.
  Future<CoverSaved> set(String id, String serverCover, List<int> jpeg) async {
    final c = ref.read(clientProvider);
    if (c == null) throw Exception('Not signed in');
    // a new file name each time, so the picture already drawn from the old file isn't reused
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'playlist_covers'));
    await dir.create(recursive: true);
    final server = md5.convert(utf8.encode(c.creds.base)).toString().substring(0, 10);
    final file = File(p.join(dir.path, '$server-${_safe(id)}-${DateTime.now().millisecondsSinceEpoch}.jpg'));
    await file.writeAsBytes(jpeg, flush: true);
    var saved = CoverSaved.onServer;
    try {
      await c.setPlaylistImage(id, jpeg);
    } on CoverRefused {
      saved = CoverSaved.onPhone;
    } catch (_) {
      await file.delete().catchError((_) => file);
      rethrow;
    }
    final old = state[id];
    await _store({
      ...state,
      id: CustomCover(path: file.path, serverWas: serverCover, phoneOnly: saved == CoverSaved.onPhone),
    });
    if (old != null) await _deleteFile(old.path);
    return saved;
  }

  /// Back to the server's own picture (a mix of the album covers).
  Future<void> reset(String id) async {
    final c = ref.read(clientProvider);
    final mine = state[id];
    if (c != null && (mine == null || !mine.phoneOnly)) {
      try {
        await c.removePlaylistImage(id);
      } on CoverRefused {
        // nothing on the server to take off
      }
    }
    await forget(id);
  }

  /// Drops the phone's copy (the playlist was deleted, or the server has the picture now).
  Future<void> forget(String id) async {
    final mine = state[id];
    if (mine == null) return;
    await _store({...state}..remove(id));
    await _deleteFile(mine.path);
  }

  /// Drops copies the server has caught up with (called when a playlist's cover id is known).
  void tidy(String id, String serverCover) {
    if (coverIsStale(state[id], serverCover)) forget(id);
  }

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  static Future<void> _deleteFile(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }
}
