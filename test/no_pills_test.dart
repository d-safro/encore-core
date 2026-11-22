// Nothing in Encore is pill-shaped: buttons, chips, segmented controls, search fields, the open tab and the
// bottom bar's highlight are rounded rectangles whose corners follow Settings → Appearance → Corners.
import 'package:encore_core/app.dart';
import 'package:encore_core/core/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

ThemeData _theme(Brightness b, [Settings s = const Settings()]) =>
    encoreTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4), brightness: b), s);

Widget _controls() => Scaffold(
  body: SingleChildScrollView(
    child: Column(
      children: [
        FilledButton(onPressed: () {}, child: const Text('Sign in')),
        FilledButton.tonalIcon(onPressed: () {}, icon: const Icon(Icons.add), label: const Text('New playlist')),
        OutlinedButton(onPressed: () {}, child: const Text('Follow')),
        TextButton(onPressed: () {}, child: const Text('Cancel')),
        ElevatedButton(onPressed: () {}, child: const Text('Raised')),
        SegmentedButton<int>(
          segments: const [ButtonSegment(value: 0, label: Text('Week')), ButtonSegment(value: 1, label: Text('Month'))],
          selected: const {0},
          onSelectionChanged: (_) {},
        ),
        ActionChip(label: const Text('Shuffle all'), onPressed: () {}),
        FilterChip(label: const Text('Autoplay'), selected: true, onSelected: (_) {}),
        ChoiceChip(label: const Text('320'), selected: false, onSelected: (_) {}),
        const Chip(label: Text('Tag')),
        const SearchBar(hintText: 'What do you want to play?'),
        FloatingActionButton.extended(onPressed: () {}, label: const Text('New playlist')),
      ],
    ),
  ),
  bottomNavigationBar: NavigationBar(
    destinations: const [
      NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
      NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
    ],
  ),
);

/// Every shape drawn under [root] that is a pill: a stadium, or a rounded rectangle whose corners take up the
/// whole of its height.
List<String> _pills(WidgetTester t, Finder root) {
  final found = <String>[];
  for (final e in find.descendant(of: root, matching: find.byType(Material)).evaluate()) {
    final m = e.widget as Material;
    final shape = m.shape ?? (m.borderRadius == null ? null : RoundedRectangleBorder(borderRadius: m.borderRadius!));
    final size = (e.renderObject as RenderBox?)?.size;
    if (shape == null || size == null || size.isEmpty) continue;
    final label = '${e.findAncestorWidgetOfExactType<FilledButton>() ?? e.widget}';
    if (shape is StadiumBorder) found.add('stadium: $label');
    if (shape is RoundedRectangleBorder) {
      final r = shape.borderRadius.resolve(TextDirection.ltr).topLeft.x;
      if (r >= size.shortestSide / 2 - 0.5) found.add('pill ($r on ${size.height}): $label');
    }
  }
  return found;
}

void main() {
  for (final b in Brightness.values) {
    testWidgets('no pills in the ${b.name} theme', (t) async {
      t.view.physicalSize = const Size(900, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(theme: _theme(b), home: _controls()));
      await t.pumpAndSettle();
      expect(_pills(t, find.byType(Scaffold)), isEmpty);
      // the bottom bar's highlight
      final indicator = t.widget<NavigationIndicator>(find.byType(NavigationIndicator).first);
      expect(indicator.shape, isA<RoundedRectangleBorder>());
      // the open tab: a line under it, not a filled pill
      expect(_theme(b).tabBarTheme.indicator, isA<UnderlineTabIndicator>());
      expect(_theme(b).navigationRailTheme.indicatorShape, isA<RoundedRectangleBorder>());
    });
  }

  test('the corners follow Settings → Appearance → Corners', () {
    double radius(String corners) {
      final theme = _theme(Brightness.dark, const Settings().copyWith({'corners': corners}));
      final shape = theme.filledButtonTheme.style!.shape!.resolve({})! as RoundedRectangleBorder;
      return shape.borderRadius.resolve(TextDirection.ltr).topLeft.x;
    }

    expect(radius('soft'), 10);
    expect(radius('square'), lessThan(radius('small')));
    expect(radius('small'), lessThan(radius('soft')));
    expect(radius('round'), greaterThan(radius('soft')));
    // even the roundest setting leaves a 40 px button well short of a pill
    expect(radius('round'), lessThan(20));
    final chip = _theme(Brightness.dark).chipTheme.shape! as RoundedRectangleBorder;
    expect(chip.borderRadius.resolve(TextDirection.ltr).topLeft.x, 8);
  });
}
