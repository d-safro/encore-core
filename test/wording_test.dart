import 'package:encore/ui/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('counts read naturally: one album, two albums', () {
    expect(plural(1, 'album'), '1 album');
    expect(plural(2, 'album'), '2 albums');
    expect(plural(0, 'episode'), '0 episodes');
    expect(plural(1, 'play'), '1 play');
    expect(plural(3, 'person', 'people'), '3 people');
    expect(nSongs(1), '1 song');
    expect(nSongs(12), '12 songs');
  });
}
