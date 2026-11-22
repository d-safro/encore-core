import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'models.dart';

/// Playlists kept on this device (Library > On this device): they can hold files on this device and songs from
/// your server, side by side. Your server's playlists can't hold a file it doesn't have, so these are the way
/// to mix them. Kept in the pref `devicePlaylists`, not synced (the files are only here).
class DevicePlaylist {
  const DevicePlaylist(this.id, this.name, this.songs);
  final String id, name;
  final List<Song> songs;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'songs': [for (final s in songs) s.toJson()]};

  static DevicePlaylist? fromJson(Object? j) {
    if (j is! Map || j['id'] == null) return null;
    return DevicePlaylist('${j['id']}', '${j['name'] ?? ''}', [
      for (final s in (j['songs'] as List? ?? const []))
        if (s is Map) Song.fromJson(s.cast<String, dynamic>()),
    ]);
  }
}

class DevicePlaylistsNotifier extends Notifier<List<DevicePlaylist>> {
  @override
  List<DevicePlaylist> build() {
    try {
      return [for (final j in jsonDecode(prefs.getString('devicePlaylists') ?? '[]') as List) ?DevicePlaylist.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  void _save(List<DevicePlaylist> l) {
    state = l;
    prefs.setString('devicePlaylists', jsonEncode([for (final p in l) p.toJson()]));
  }

  DevicePlaylist create(String name, [List<Song> songs = const []]) {
    final p = DevicePlaylist('dp-${DateTime.now().microsecondsSinceEpoch}', name.trim().isEmpty ? 'New playlist' : name.trim(), songs);
    _save([...state, p]);
    return p;
  }

  /// Adds the songs not already in it; returns how many were added.
  int add(String id, List<Song> songs) {
    var added = 0;
    _save([
      for (final p in state)
        if (p.id != id)
          p
        else
          () {
            final have = {for (final s in p.songs) s.id};
            final fresh = [for (final s in songs) if (have.add(s.id)) s];
            added = fresh.length;
            return DevicePlaylist(p.id, p.name, [...p.songs, ...fresh]);
          }(),
    ]);
    return added;
  }

  void removeAt(String id, int index) => _edit(id, (l) => l.removeAt(index));

  /// Moves the song at [from] to [to] (ReorderableListView's indexes: [to] counts the song still in place).
  void move(String id, int from, int to) => _edit(id, (l) => l.insert(to > from ? to - 1 : to, l.removeAt(from)));

  void _edit(String id, void Function(List<Song> songs) change) => _save([
    for (final p in state)
      if (p.id != id) p else DevicePlaylist(p.id, p.name, [...p.songs]..let(change)),
  ]);

  void rename(String id, String name) =>
      _save([for (final p in state) p.id == id ? DevicePlaylist(p.id, name.trim(), p.songs) : p]);

  void delete(String id) => _save([for (final p in state) if (p.id != id) p]);
}

final devicePlaylistsProvider = NotifierProvider<DevicePlaylistsNotifier, List<DevicePlaylist>>(DevicePlaylistsNotifier.new);

extension<T> on List<T> {
  List<T> let(void Function(List<T>) f) {
    f(this);
    return this;
  }
}
