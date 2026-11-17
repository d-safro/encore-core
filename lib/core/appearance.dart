import 'package:material_ui/material_ui.dart';

import 'settings.dart';

/// A "look": one tap in Settings → Appearance sets a bundle of appearance options at once.
/// Text size, typeface, contrast, Home's sections and the tab order are personal, so looks leave them alone.
/// Colours too, except where a look is about them: Big artwork takes them from the cover, Minimal is pure black
/// (switching to another look afterwards keeps those, like any colour choice).
enum Look {
  encore('Encore', 'The standard look: roomy cards, a big cover, a floating player bar'),
  compact('Compact', 'More on screen: lists, smaller covers, tighter rows'),
  artwork('Big artwork', 'Large covers everywhere, colours from the album art'),
  minimal('Minimal', 'Pure black, no blur, a small cover and big titles');

  const Look(this.label, this.description);
  final String label, description;

  /// The settings this look sets (keys as stored in Settings.toJson).
  Map<String, Object> get changes => switch (this) {
    Look.encore => const {
      'corners': 'soft',
      'compact': false,
      'cardSize': 'medium',
      'albumGrid': true,
      'playerLayout': 'bigCover',
      'playerBlur': 'soft',
      'miniPlayer': 'floating',
      'navLabels': 'selected',
      'showQuickPills': true,
      'showJumpBackIn': true,
      'showGreeting': true,
    },
    Look.compact => const {
      'corners': 'small',
      'compact': true,
      'cardSize': 'small',
      'albumGrid': false,
      'playerLayout': 'bigCover',
      'playerBlur': 'soft',
      'miniPlayer': 'slim',
      'navLabels': 'never',
      'showQuickPills': true,
      'showJumpBackIn': true,
      'showGreeting': true,
    },
    Look.artwork => const {
      'corners': 'round',
      'compact': false,
      'cardSize': 'large',
      'albumGrid': true,
      'playerLayout': 'bigCover',
      'playerBlur': 'strong',
      'miniPlayer': 'floating',
      'navLabels': 'selected',
      'showQuickPills': true,
      'showJumpBackIn': true,
      'showGreeting': true,
      'themeSource': 'albumArt',
    },
    Look.minimal => const {
      'corners': 'square',
      'compact': false,
      'cardSize': 'medium',
      'albumGrid': true,
      'playerLayout': 'minimal',
      'playerBlur': 'off',
      'miniPlayer': 'flat',
      'navLabels': 'never',
      'showQuickPills': false,
      'showJumpBackIn': true,
      'showGreeting': true,
      'pureBlack': true,
    },
  };

  /// What these settings would look like with this look applied (for the previews).
  Settings applyTo(Settings s) => s.copyWith(changes);
}

/// The look the settings match right now, or null when options were changed by hand ("Custom").
Look? lookOf(Settings s) {
  final now = s.toJson();
  for (final l in Look.values) {
    if (l.changes.entries.every((e) => now[e.key] == e.value)) return l;
  }
  return null;
}

/// Every appearance setting, back to how Encore comes (including colours, text and tabs).
Map<String, Object?> appearanceDefaults() {
  final d = const Settings().toJson();
  return {for (final k in appearanceKeys) k: d[k]};
}

/// The settings that Settings → Appearance owns (what "Reset to default" puts back).
const appearanceKeys = [
  'themeSource',
  'accentColor',
  'pureBlack',
  'highContrast',
  'fontFamily',
  'textScale',
  'corners',
  'compact',
  'cardSize',
  'albumGrid',
  'homeSections',
  'showQuickPills',
  'showJumpBackIn',
  'showGreeting',
  'playerLayout',
  'playerBlur',
  'miniPlayer',
  'navTabs',
  'navLabels',
];

/// The appearance options widgets need while drawing, carried on the theme so every screen can reach them
/// with `AppLook.of(context)` (and so they change live, with the theme).
class AppLook extends ThemeExtension<AppLook> {
  const AppLook({
    this.corner = 1,
    this.compact = false,
    this.cardSize = CardSize.medium,
    this.playerLayout = PlayerLayout.bigCover,
    this.playerBlur = PlayerBlur.soft,
    this.miniPlayer = MiniPlayerStyle.floating,
  });

  factory AppLook.from(Settings s) => AppLook(
    corner: cornerScale(s.corners),
    compact: s.compact,
    cardSize: s.cardSize,
    playerLayout: s.playerLayout,
    playerBlur: s.playerBlur,
    miniPlayer: s.miniPlayer,
  );

  final double corner; // multiplies every corner radius
  final bool compact;
  final CardSize cardSize;
  final PlayerLayout playerLayout;
  final PlayerBlur playerBlur;
  final MiniPlayerStyle miniPlayer;

  static AppLook of(BuildContext context) => Theme.of(context).extension<AppLook>() ?? const AppLook();

  static double cornerScale(Corners c) => switch (c) {
    Corners.square => 0.2,
    Corners.small => 0.55,
    Corners.soft => 1.0,
    Corners.round => 1.5,
  };

  /// A corner radius designed for the standard look, scaled to the chosen roundness.
  double r(double radius) => radius * corner;

  /// Width of an album card on a shelf.
  double get cardWidth => switch (cardSize) {
    CardSize.small => 120,
    CardSize.medium => 148,
    CardSize.large => 184,
  };

  /// Widest a card may get in the library's album grid.
  double get gridExtent => switch (cardSize) {
    CardSize.small => 140,
    CardSize.medium => 190,
    CardSize.large => 260,
  };

  @override
  AppLook copyWith({
    double? corner,
    bool? compact,
    CardSize? cardSize,
    PlayerLayout? playerLayout,
    PlayerBlur? playerBlur,
    MiniPlayerStyle? miniPlayer,
  }) => AppLook(
    corner: corner ?? this.corner,
    compact: compact ?? this.compact,
    cardSize: cardSize ?? this.cardSize,
    playerLayout: playerLayout ?? this.playerLayout,
    playerBlur: playerBlur ?? this.playerBlur,
    miniPlayer: miniPlayer ?? this.miniPlayer,
  );

  @override
  AppLook lerp(AppLook? other, double t) {
    if (other == null) return this;
    final pick = t < 0.5 ? this : other;
    return pick.copyWith(corner: corner + (other.corner - corner) * t);
  }
}

/// The bottom tabs (also listed in Settings → Appearance to pick and reorder).
const navDestinations = {
  'home': (path: '/home', icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
  'discover': (
    path: '/discover',
    icon: Icon(Icons.auto_awesome_outlined),
    selectedIcon: Icon(Icons.auto_awesome),
    label: 'Discover',
  ),
  'library': (
    path: '/library',
    icon: Icon(Icons.library_music_outlined),
    selectedIcon: Icon(Icons.library_music_rounded),
    label: 'Library',
  ),
  'search': (
    path: '/search',
    icon: Icon(Icons.search_rounded),
    selectedIcon: Icon(Icons.search_rounded),
    label: 'Search',
  ),
};
