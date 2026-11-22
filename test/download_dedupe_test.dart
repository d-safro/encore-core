import 'package:encore_core/data/library.dart';
import 'package:encore_core/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Song s(String title, int? duration, {String artist = 'Test Band', String id = 'x'}) =>
      Song(id: id, title: title, artist: artist, duration: duration);
  bool same(Song a, Song b) => DownloadsNotifier.sameRecording(a, b);

  test('the same recording twice is stored once: lengths within 2 s', () {
    expect(same(s('Test Song', 200), s('Test Song', 202)), isTrue);
    expect(same(s('Test Song', 200), s('Test Song', 203)), isFalse);
    expect(same(s('Test Song (2011 Remaster)', 200), s('Test Song', 201)), isTrue);
    expect(same(s('Test Song - Remastered 2009', 200), s('Test Song', 200)), isTrue);
  });

  test("an unknown length isn't taken for the same", () {
    expect(same(s('Test Song', null), s('Test Song', 200)), isFalse);
    expect(same(s('Test Song', null), s('Test Song', null)), isFalse);
  });

  test('edits, versions, mixes and live takes are other recordings', () {
    for (final other in [
      'Test Song (Radio Edit)',
      'Test Song (Acoustic Version)',
      'Test Song (Live)',
      'Test Song (Club Mix)',
      'Test Song - Single Version',
      'Test Song (2011 Remastered Version)',
      'Test Song - Live 2009 Remaster',
    ]) {
      expect(same(s(other, 200), s('Test Song', 200)), isFalse, reason: other);
    }
    expect(same(s('Test Song (Radio Edit)', 200), s('Test Song (Radio Edit)', 201)), isTrue);
  });
}
