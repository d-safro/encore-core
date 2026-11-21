import 'package:encore/playback/private_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a private session lasts 6 hours', () {
    final start = DateTime(2026, 11, 21, 15, 40);
    final end = privateSessionEnd(start);
    expect(end, DateTime(2026, 11, 21, 21, 40));
    expect(privateSessionOn(end, start), isTrue);
    expect(privateSessionOn(end, end.subtract(const Duration(seconds: 1))), isTrue);
    expect(privateSessionOn(end, end), isFalse);
    expect(privateSessionOn(null, start), isFalse);
  });

  test('starts off and toggles on and off', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(privateSessionProvider), isNull);
    final n = c.read(privateSessionProvider.notifier);
    expect(n.on, isFalse);
    n.toggle();
    expect(n.on, isTrue);
    final until = c.read(privateSessionProvider)!;
    expect(until.difference(DateTime.now()).inMinutes, closeTo(360, 1));
    n.set(false);
    expect(c.read(privateSessionProvider), isNull);
  });

  test('labels say when it ends', () {
    expect(privateSessionLabel(DateTime(2026, 1, 1, 9, 5)), contains('09:05'));
    expect(privateSessionLabel(null), contains('6 hours'));
  });
}
