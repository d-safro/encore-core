import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/appearance.dart';
import '../../core/settings.dart';
import '../actions.dart';
import '../widgets.dart';

const accentChoices = [
  0xFF6750A4, 0xFF4355B9, 0xFF0061A4, 0xFF006A6A, 0xFF006E1C, 0xFF386A20, //
  0xFF5D5F00, 0xFF8B5000, 0xFFA0410D, 0xFFB3261E, 0xFF984061, 0xFF7D5260,
];

const homeSectionNames = {
  'yourMixes': 'Repertoire · Your mixes',
  'recent': 'Recently played',
  'newest': 'Recently added',
  'frequent': 'Most played',
  'starred': 'Favourite albums',
  'random': 'Discover',
  'highest': 'Top rated',
  'playlists': 'Playlists',
};

/// Settings → Appearance: a look (a bundle of options) to start from, then each option on its own.
/// Everything applies straight away.
class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    void set(String k, Object v) => n.update({k: v});
    final look = lookOf(s);

    Widget choice<T>(IconData icon, String title, Map<T, String> options, T selected, void Function(T) onChanged) =>
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SegmentedButton<T>(
              showSelectedIcon: false,
              style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.padded), // 48 dp to touch (compact was 40)
              segments: [for (final e in options.entries) ButtonSegment(value: e.key, label: Text(e.value))],
              selected: {selected},
              onSelectionChanged: (v) => onChanged(v.first),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Appearance'),
        actions: [
          TextButton(
            onPressed: () async {
              if (await confirm(
                context,
                'Reset to default?',
                'Colours, text, shapes, Home, the player and the tabs go back to how Encore comes.',
                ok: 'Reset',
              )) {
                n.update(appearanceDefaults());
              }
            },
            child: const Text('Reset to default'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SectionTitle('Look', subtitle: look == null ? 'Custom: you changed options below' : look.description),
          SizedBox(
            height: 236,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final l in Look.values)
                  _LookCard(look: l, settings: s, selected: look == l, onTap: () => n.update(l.changes)),
              ],
            ),
          ),

          const SectionTitle('Colours'),
          choice(
            Icons.dark_mode_outlined,
            'Theme',
            const {AppTheme.dark: 'Dark', AppTheme.light: 'Light', AppTheme.system: 'System'},
            s.appTheme,
            (v) => set('appTheme', v.name),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Colours from'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SegmentedButton<ThemeSource>(
                showSelectedIcon: false,
                style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.padded), // 48 dp to touch (compact was 40)
                segments: const [
                  ButtonSegment(value: ThemeSource.wallpaper, label: Text('Wallpaper')),
                  ButtonSegment(value: ThemeSource.albumArt, label: Text('Album art')),
                  ButtonSegment(value: ThemeSource.fixed, label: Text('Pick')),
                ],
                selected: {s.themeSource},
                onSelectionChanged: (v) => set('themeSource', v.first.name),
              ),
            ),
          ),
          if (s.themeSource == ThemeSource.fixed)
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 4, 16, 8),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in accentChoices)
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => set('accentColor', c),
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: Color(c),
                        child: s.accentColor == c ? const Icon(Icons.check, color: Colors.white) : null,
                      ),
                    ),
                ],
              ),
            ),
          SwitchListTile(
            secondary: const Icon(Icons.brightness_2_outlined),
            title: const Text('Pure black'),
            subtitle: Text(s.appTheme == AppTheme.light
                ? 'For the dark theme'
                : 'Black backgrounds in the dark theme (saves battery on OLED screens)'),
            value: s.pureBlack,
            onChanged: s.appTheme == AppTheme.light ? null : (v) => set('pureBlack', v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.contrast),
            title: const Text('High contrast'),
            subtitle: const Text('Brighter grey text and clearer edges'),
            value: s.highContrast,
            onChanged: (v) => set('highContrast', v),
          ),

          const SectionTitle('Text'),
          choice(
            Icons.font_download_outlined,
            'Typeface',
            const {'inter': 'Inter', 'system': 'Phone\'s'},
            s.fontFamily,
            (v) => set('fontFamily', v),
          ),
          ListTile(
            leading: const Icon(Icons.format_size_rounded),
            title: Text('Text size: ${(s.textScale * 100).round()}%'),
            subtitle: Slider(
              value: s.textScale,
              min: 0.85,
              max: 1.3,
              divisions: 9,
              label: '${(s.textScale * 100).round()}%',
              onChanged: (v) => set('textScale', double.parse(v.toStringAsFixed(2))),
            ),
          ),

          const SectionTitle('Shapes and spacing'),
          choice(
            Icons.rounded_corner_rounded,
            'Corners',
            const {Corners.square: 'Square', Corners.small: 'Small', Corners.soft: 'Soft', Corners.round: 'Round'},
            s.corners,
            (v) => set('corners', v.name),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.density_medium_rounded),
            title: const Text('Compact'),
            subtitle: const Text('Tighter rows and buttons, more on screen'),
            value: s.compact,
            onChanged: (v) => set('compact', v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.motion_photos_off_outlined),
            title: const Text('Reduce animations'),
            subtitle: const Text('No sliding pages, colour fades or smooth scrolling. On by itself when the phone\'s '
                '"Remove animations" is on'),
            value: s.reduceMotion,
            onChanged: (v) => set('reduceMotion', v),
          ),

          const SectionTitle('Albums'),
          choice(
            Icons.grid_view_rounded,
            'Library albums as',
            const {true: 'Grid', false: 'List'},
            s.albumGrid,
            (v) => set('albumGrid', v),
          ),
          choice(
            Icons.photo_size_select_large_rounded,
            'Card size',
            const {CardSize.small: 'Small', CardSize.medium: 'Medium', CardSize.large: 'Large'},
            s.cardSize,
            (v) => set('cardSize', v.name),
          ),

          const SectionTitle('Home'),
          ListTile(
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: const Text('Sections'),
            subtitle: Text(s.homeSections.map((k) => homeSectionNames[k] ?? k).join(', ')),
            onTap: () => _editHome(context, ref, s),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.waving_hand_outlined),
            title: const Text('Greeting'),
            subtitle: const Text('"Good morning" at the top'),
            value: s.showGreeting,
            onChanged: (v) => set('showGreeting', v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.smart_button_rounded),
            title: const Text('Shortcut buttons'),
            subtitle: const Text('Shuffle all, Liked songs, Made for you…'),
            value: s.showQuickPills,
            onChanged: (v) => set('showQuickPills', v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.history_rounded),
            title: const Text('Jump back in'),
            subtitle: const Text('Albums you played lately, as small tiles'),
            value: s.showJumpBackIn,
            onChanged: (v) => set('showJumpBackIn', v),
          ),

          const SectionTitle('Player'),
          choice(
            Icons.album_outlined,
            'Layout',
            const {
              PlayerLayout.bigCover: 'Big cover',
              PlayerLayout.coverLyrics: 'With lyrics',
              PlayerLayout.minimal: 'Minimal',
            },
            s.playerLayout,
            (v) => set('playerLayout', v.name),
          ),
          choice(
            Icons.blur_on_rounded,
            'Blurred artwork behind',
            const {PlayerBlur.off: 'Off', PlayerBlur.soft: 'Soft', PlayerBlur.strong: 'Strong'},
            s.playerBlur,
            (v) => set('playerBlur', v.name),
          ),
          choice(
            Icons.picture_in_picture_alt_outlined,
            'Player bar',
            const {MiniPlayerStyle.floating: 'Floating', MiniPlayerStyle.flat: 'Flat', MiniPlayerStyle.slim: 'Slim'},
            s.miniPlayer,
            (v) => set('miniPlayer', v.name),
          ),

          const SectionTitle('Tabs'),
          ListTile(
            leading: const Icon(Icons.tab_rounded),
            title: const Text('Tabs and their order'),
            subtitle: Text(s.navTabs.map((k) => navDestinations[k]!.label).join(', ')),
            onTap: () => _editTabs(context, ref, s),
          ),
          choice(
            Icons.label_outline_rounded,
            'Tab names',
            const {NavLabels.always: 'Always', NavLabels.selected: 'Open tab', NavLabels.never: 'Never'},
            s.navLabels,
            (v) => set('navLabels', v.name),
          ),
        ],
      ),
    );
  }

  /// Tick and drag a list of keys (Home sections, tabs). [locked] can't be unticked; at least [min] stay ticked.
  static Future<List<String>> _pickAndOrder(
    BuildContext context, {
    required String title,
    required List<String> all,
    required List<String> chosen,
    required String Function(String) name,
    String? locked,
    int min = 0,
  }) async {
    var picked = [...chosen.where(all.contains)];
    await showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final order = [...picked, ...all.where((x) => !picked.contains(x))];
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(title: Text(title), subtitle: const Text('Drag to reorder')),
                Flexible(
                  child: ReorderableListView(
                    shrinkWrap: true,
                    onReorder: (a, b) => setState(() {
                      if (b > a) b--;
                      order.insert(b, order.removeAt(a));
                      picked = order.where(picked.contains).toList();
                    }),
                    children: [
                      for (final k in order)
                        CheckboxListTile(
                          key: ValueKey(k),
                          value: picked.contains(k),
                          title: Text(name(k)),
                          subtitle: k == locked ? const Text('Settings are reached from here, so it stays') : null,
                          secondary: const Icon(Icons.drag_handle),
                          onChanged: k == locked || (picked.contains(k) && picked.length <= min)
                              ? null
                              : (v) => setState(() {
                                  v! ? picked.add(k) : picked.remove(k);
                                  picked = order.where(picked.contains).toList();
                                }),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    return picked;
  }

  Future<void> _editHome(BuildContext context, WidgetRef ref, Settings s) async {
    final picked = await _pickAndOrder(
      context,
      title: 'Home screen sections',
      all: homeSectionNames.keys.toList(),
      chosen: s.homeSections,
      name: (k) => homeSectionNames[k]!,
    );
    ref.read(settingsProvider.notifier).update({'homeSections': picked});
  }

  Future<void> _editTabs(BuildContext context, WidgetRef ref, Settings s) async {
    final picked = await _pickAndOrder(
      context,
      title: 'Tabs',
      all: Settings.defaultNavTabs,
      chosen: s.navTabs,
      name: (k) => navDestinations[k]!.label,
      locked: 'home',
      min: 2,
    );
    ref.read(settingsProvider.notifier).update({'navTabs': picked});
  }
}

/// One look: a small drawing of Home in that look, its name, and a tick when it's the current one.
class _LookCard extends StatelessWidget {
  const _LookCard({required this.look, required this.settings, required this.selected, required this.onTap});
  final Look look;
  final Settings settings;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: selected ? cs.primary : cs.outlineVariant.withValues(alpha: 0.4),
                    width: 2.5,
                  ),
                ),
                child: LookPreview(settings: look.applyTo(settings)),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) Icon(Icons.check_circle_rounded, size: 16, color: cs.primary),
                  if (selected) const SizedBox(width: 4),
                  Text(look.label, style: t.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A drawing of the Home screen as these settings would show it: shelves, rows, the player bar and the tabs.
class LookPreview extends StatelessWidget {
  const LookPreview({super.key, required this.settings});
  final Settings settings;

  static const width = 104.0, height = 184.0;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final cs = Theme.of(context).colorScheme;
    final r = AppLook.cornerScale(s.corners);
    final light = Theme.of(context).brightness == Brightness.light;
    final bg = light ? cs.surfaceContainerLow : (s.pureBlack ? Colors.black : const Color(0xFF16171C));
    final ink = cs.onSurface.withValues(alpha: s.highContrast ? 0.5 : 0.3);
    final tile = cs.onSurface.withValues(alpha: 0.14);
    final accent = cs.primary;
    Widget bar(double w, double h, Color c, [double radius = 2]) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(radius)),
    );
    final (cards, side) = switch (s.cardSize) {
      CardSize.small => (4, 19.0),
      CardSize.medium => (3, 26.0),
      CardSize.large => (2, 38.0),
    };
    final shelf = Row(
      children: [
        for (var i = 0; i < cards; i++)
          Padding(padding: const EdgeInsets.only(right: 4), child: bar(side, side, tile, 4 * r)),
      ],
    );
    final rows = s.albumGrid
        ? Wrap(spacing: 4, runSpacing: 4, children: [for (var i = 0; i < 4; i++) bar(42, 22, tile, 4 * r)])
        : Column(
            children: [
              for (var i = 0; i < (s.compact ? 4 : 3); i++)
                Padding(
                  padding: EdgeInsets.only(bottom: s.compact ? 3 : 6),
                  child: Row(
                    children: [
                      bar(s.compact ? 10 : 14, s.compact ? 10 : 14, tile, 2 * r),
                      const SizedBox(width: 4),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [bar(46, 3, ink), const SizedBox(height: 2), bar(30, 3, ink.withValues(alpha: 0.15))],
                      ),
                    ],
                  ),
                ),
            ],
          );
    final mini = switch (s.miniPlayer) {
      MiniPlayerStyle.flat => Container(
        height: 16,
        color: cs.onSurface.withValues(alpha: 0.08),
        child: Align(alignment: Alignment.topLeft, child: bar(40, 1.5, accent, 0)),
      ),
      MiniPlayerStyle.slim => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Container(
          height: 12,
          decoration: BoxDecoration(color: tile, borderRadius: BorderRadius.circular(3 * r)),
        ),
      ),
      MiniPlayerStyle.floating => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Container(
          height: 18,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: tile, borderRadius: BorderRadius.circular(5 * r)),
          child: Row(children: [bar(12, 12, accent.withValues(alpha: 0.6), 2 * r)]),
        ),
      ),
    };
    final nav = SizedBox(
      height: s.navLabels == NavLabels.never ? 14 : 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var i = 0; i < s.navTabs.length; i++)
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                bar(8, 8, i == 0 ? accent : ink, 4),
                if (s.navLabels == NavLabels.always || (s.navLabels == NavLabels.selected && i == 0)) ...[
                  const SizedBox(height: 2),
                  bar(10, 2, i == 0 ? accent : ink),
                ],
              ],
            ),
        ],
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: width,
        height: height,
        color: bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(7, 10, 0, 0),
                // like a real screen, what doesn't fit is cut off at the bottom
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    maxHeight: double.infinity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (s.showGreeting) ...[
                          bar(52, 6, cs.onSurface.withValues(alpha: 0.7)),
                          const SizedBox(height: 6),
                        ],
                        if (s.showQuickPills) ...[
                          Row(
                            children: [
                              for (var i = 0; i < 3; i++)
                                Padding(padding: const EdgeInsets.only(right: 3), child: bar(24, 7, tile, 4)),
                            ],
                          ),
                          const SizedBox(height: 7),
                        ],
                        bar(34, 4, ink),
                        const SizedBox(height: 4),
                        shelf,
                        const SizedBox(height: 8),
                        bar(28, 4, ink),
                        const SizedBox(height: 4),
                        rows,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            mini,
            if (s.miniPlayer != MiniPlayerStyle.flat) const SizedBox(height: 3),
            nav,
          ],
        ),
      ),
    );
  }
}
