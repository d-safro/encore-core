import 'package:encore/core/settings.dart';
import 'package:encore/data/song_id.dart';
import 'package:encore/ui/whats_playing.dart';
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

  test('finds are remembered, newest first, once each', () async {
    await rememberIdentified({'id': 'a', 'title': 'A', 'artist': 'X'});
    await rememberIdentified({'id': 'b', 'title': 'B', 'artist': 'Y'});
    await rememberIdentified({'id': 'a', 'title': 'A', 'artist': 'X'});
    expect(identifiedSongs().map((e) => e.$1.id), ['a', 'b']);
  });
}
