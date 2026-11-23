import 'package:audio_service/audio_service.dart';

import '../core/settings.dart';
import '../data/models.dart' show isPodcastId;

// Skip back / forward by a few seconds (Settings › Playback): the player's buttons, the desktop's keys, and
// through the media session the notification, lock screen, Android Auto, headphones and a watch.

/// What a skip does: go to a place in the song, or on to the next one.
sealed class SkipStep {
  const SkipStep();
}

class SkipSeek extends SkipStep {
  const SkipSeek(this.to);
  final Duration to;
  @override
  bool operator ==(Object other) => other is SkipSeek && other.to == to;
  @override
  int get hashCode => to.hashCode;
  @override
  String toString() => 'SkipSeek($to)';
}

class SkipNext extends SkipStep {
  const SkipNext();
  @override
  bool operator ==(Object other) => other is SkipNext;
  @override
  int get hashCode => 0;
  @override
  String toString() => 'SkipNext()';
}

/// A skip of [by] from [position] in a song [length] long (null or zero: not known). Never before the start;
/// past the end it's the next song, as a long seek would do, or the very end when there's none.
SkipStep skipStep(Duration position, Duration by, Duration? length, {required bool hasNext}) {
  final to = position + by;
  if (to <= Duration.zero) return const SkipSeek(Duration.zero);
  if (length == null || length <= Duration.zero || to < length) return SkipSeek(to);
  return hasNext ? const SkipNext() : SkipSeek(length);
}

/// Whether what's playing (its media id) gets the skip buttons: not an internet radio station (there's nothing
/// to skip in a live stream), and only an episode or audiobook when that's what the setting says.
bool skipShownFor(Settings s, String? id) {
  if (id == null || id.isEmpty || id.startsWith('radio-')) return false;
  return s.skipButtons == SkipButtons.everything || isPodcastId(id);
}

/// What a screen reader says for a skip button.
String skipLabel(int seconds, {required bool forward}) =>
    '${forward ? 'Forward' : 'Back'} $seconds ${seconds == 1 ? 'second' : 'seconds'}';

/// The media session's buttons with skip back / forward added (when [skipShownFor]), from the usual
/// [previous, play/pause, next, heart, shuffle]. The notification's compact view keeps previous, play and
/// next. Android 13 and later draw the first two custom buttons beside those (skip back and forward become
/// custom ones there): heart and shuffle for music, the skip buttons for episodes and audiobooks. Android
/// Auto shows them all.
({List<MediaControl> controls, List<int> compact}) withSkipControls(
  List<MediaControl> usual, {
  required Settings settings,
  required String? id,
}) {
  if (usual.length < 3 || !skipShownFor(settings, id)) return (controls: usual, compact: const [0, 1, 2]);
  final back = MediaControl(
    androidIcon: 'drawable/audio_service_fast_rewind',
    label: skipLabel(settings.skipBack, forward: false),
    action: MediaAction.rewind,
  );
  final forward = MediaControl(
    androidIcon: 'drawable/audio_service_fast_forward',
    label: skipLabel(settings.skipForward, forward: true),
    action: MediaAction.fastForward,
  );
  final rest = usual.sublist(3);
  if (isPodcastId(id!)) {
    // ⟲ ⏮ ⏯ ⏭ ⟳ in the notification of older Androids; the skip buttons first among the custom ones
    return (controls: [back, ...usual.take(3), forward, ...rest], compact: const [1, 2, 3]);
  }
  return (controls: [...usual, back, forward], compact: const [0, 1, 2]);
}
