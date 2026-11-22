import 'dart:io';

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

  test('the features go by their names in the app, with what they are beside them', () {
    final all = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
        f.readAsStringSync(),
    ].join('\n');
    for (final shown in [
      "'Ensemble'", 'Listen together', 'Chorus · Invite to edit', "'Repertoire'", 'Marquee · Concerts near you',
      'Curtain Call · Your', 'Libretto · Translate', 'Interlude · DJ', "Pitch · What\\'s playing?",
      'Metronome · Automix', 'Audition', 'Conductor or music-lookup',
    ]) {
      expect(all.contains(shown), isTrue, reason: shown);
    }
    for (final old in ["'Start a Jam'", "'End Jam'", "'Jam is on'", "Text('DJ')", "Text('Automix')", r"\btitle: 'Your mixes'"]) {
      expect(RegExp(old.startsWith(r'\b') ? old : RegExp.escape(old)).hasMatch(all), isFalse, reason: old);
    }
  });
}
