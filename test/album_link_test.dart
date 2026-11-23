import 'package:encore_core/data/models.dart';
import 'package:encore_core/ui/widgets.dart' show NameLink;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("a song's name leads to its album, the catalog's whole album for one you don't have", () {
    Song song(String id, String albumId, [String title = 'Wild Horses']) =>
        Song.fromJson({'id': id, 'title': title, 'albumId': albumId, 'album': 'Sticky Fingers', 'duration': 342});
    expect(NameLink.albumOf(song('1', 'al-9')), '/album/al-9');
    // ⬇ a song you don't have: its album from the catalog, where the other songs are too
    expect(NameLink.albumOf(song('dz-t-5', 'dz-a-7', '⬇ Wild Horses')), '/album/dz-a-7');
    // nothing to open
    expect(NameLink.albumOf(song('dz-t-5', '', '⬇ Wild Horses')), isNull);
    expect(NameLink.albumOf(song('1', '')), isNull);
  });
}
