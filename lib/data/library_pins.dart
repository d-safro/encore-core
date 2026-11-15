import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';

/// A playlist or album pinned to the top of the Library (like Spotify's pins). Kept on the phone.
class LibraryPin {
  const LibraryPin(this.kind, this.id, this.name, {this.cover = '', this.subtitle = ''});
  final String kind; // playlist, album
  final String id, name, cover, subtitle;
  String get key => '$kind:$id';

  Map<String, dynamic> toJson() => {'kind': kind, 'id': id, 'name': name, 'cover': cover, 'subtitle': subtitle};

  static LibraryPin? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = '${j['kind'] ?? ''}', id = '${j['id'] ?? ''}';
    if ((kind != 'playlist' && kind != 'album') || id.isEmpty) return null;
    return LibraryPin(kind, id, '${j['name'] ?? ''}', cover: '${j['cover'] ?? ''}', subtitle: '${j['subtitle'] ?? ''}');
  }
}

class LibraryPinsNotifier extends Notifier<List<LibraryPin>> {
  @override
  List<LibraryPin> build() {
    try {
      return [for (final e in jsonDecode(prefs.getString('libraryPins') ?? '[]') as List) ?LibraryPin.fromJson(e)];
    } catch (_) {
      return const [];
    }
  }

  bool isPinned(String key) => state.any((p) => p.key == key);

  /// Pin (newest on top) or unpin.
  void toggle(LibraryPin pin) {
    state = isPinned(pin.key) ? state.where((p) => p.key != pin.key).toList() : [pin, ...state];
    prefs.setString('libraryPins', jsonEncode(state.map((p) => p.toJson()).toList()));
  }
}

final libraryPinsProvider = NotifierProvider<LibraryPinsNotifier, List<LibraryPin>>(LibraryPinsNotifier.new);
