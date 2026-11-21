// The rules for adding many songs (a whole album, say) to a playlist, kept apart from the screens so they
// can be tested.

/// Which of [adding] are already in the playlist, in the order they'd be added.
List<String> alreadyIn(List<String> playlistIds, List<String> adding) {
  final have = playlistIds.toSet();
  return [for (final id in adding) if (have.contains(id)) id];
}

/// What to send: everything, or only the songs the playlist doesn't have yet. The order stays the album's.
List<String> toSend(List<String> playlistIds, List<String> adding, {required bool skipDuplicates}) {
  if (!skipDuplicates) return adding;
  final have = playlistIds.toSet();
  final seen = <String>{};
  return [for (final id in adding) if (!have.contains(id) && seen.add(id)) id];
}

/// For Undo: the positions of the songs we added at the end of the playlist, or null when the playlist
/// changed since (then undoing could remove the wrong songs, so we don't).
List<int>? undoIndexes(List<String> nowIds, int lengthBefore, List<String> added) {
  if (nowIds.length != lengthBefore + added.length) return null;
  for (var i = 0; i < added.length; i++) {
    if (nowIds[lengthBefore + i] != added[i]) return null;
  }
  return [for (var i = 0; i < added.length; i++) lengthBefore + i];
}
