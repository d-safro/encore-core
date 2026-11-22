import 'package:encore_core/core/settings.dart';
import 'package:encore_core/data/song_id.dart';
import 'package:encore_core/ui/whats_playing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('reads what the server found', () {
    final r = Identification.fromJson({
      'found': true, 'offset': 61.5, 'score': 40,
      'song': {'id': 's1', 'title': 'Sunny Afternoon', 'artist': 'The Kinks'},
    });
    expect(r.found, isTrue);
    expect(r.offset, 61.5);
    expect(identificationSummary(r), 'Sunny Afternoon · The Kinks');
    final no = Identification.fromJson({'found': false, 'indexing': true, 'songs': 120});
    expect(no.found, isFalse);
    expect(identificationSummary(no), 'not yet');
    expect(identificationSummary(Identification.fromJson({'found': false})), 'not yours');
  });

  test("the server not able to look isn't \"not one of yours\"", () {
    Identification err(String e) => Identification.fromJson({'found': false, 'error': e});
    final notSetUp = err("Song ID isn't set up on the server (songid_url)");
    expect(identificationSummary(notSetUp), "Your server can't recognise songs yet (Pitch isn't set up there)");
    expect(songIdNotSetUp(notSetUp), isTrue); // listening again won't help
    final down = err("song-id isn't running");
    expect(identificationSummary(down), "Your server's song ID isn't running right now");
    expect(songIdNotSetUp(down), isFalse);
    expect(identificationSummary(err('Something else broke')), 'Something else broke');
  });

  test('finds are remembered, newest first, once each', () async {
    await rememberIdentified({'id': 'a', 'title': 'A', 'artist': 'X'});
    await rememberIdentified({'id': 'b', 'title': 'B', 'artist': 'Y'});
    await rememberIdentified({'id': 'a', 'title': 'A', 'artist': 'X'});
    expect(identifiedSongs().map((e) => e.$1.id), ['a', 'b']);
  });
}
