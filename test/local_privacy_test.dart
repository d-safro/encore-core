import 'package:encore/data/local_files.dart';
import 'package:encore/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

(String, int) q((List<String>, int) r) => (r.$1.join(','), r.$2);

void main() {
  final local = const LocalTrack(uri: '/home/me/Music/a.flac', title: 'Mine', cover: 'file:/home/me/.local/c.jpg').toSong();
  const s1 = Song(id: 's1', title: 'One'), s2 = Song(id: 's2', title: 'Two');

  test('a local picture is never sent: it\'s a path with your home folder in it', () {
    expect(shareableCover(local.coverArt), '');
    expect(shareableCover('al-123'), 'al-123');
    expect(shareableCover('https://abs/cover'), 'https://abs/cover');
  });

  test('other devices get the server songs, from the one playing or the next', () {
    expect(q(serverQueue([s1, local, s2], 0)), (['s1', 's2'].join(','), 0));
    expect(q(serverQueue([s1, local, s2], 1)), (['s1', 's2'].join(','), 1)); // a local file plays: from the next server song
    expect(q(serverQueue([s1, local, s2], 2)), (['s1', 's2'].join(','), 1));
    expect(q(serverQueue([s1, s2, local], 2)), (['s1', 's2'].join(','), 0)); // nothing after it
    expect(q(serverQueue([local], 0)), (<String>[].join(','), 0));
  });
}
