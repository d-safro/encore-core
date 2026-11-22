import 'package:encore_core/data/sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('which way a synced value goes', () {
    SyncStep step(String? local, String? server, {int serverAt = 200, int localAt = 0, bool merge = false}) =>
        syncStep(local: local, last: '"a"', lastAt: 100, server: server, serverAt: serverAt, localAt: localAt, mergeable: merge);

    test('changed only here: sent; only there: taken', () {
      expect(step('"b"', '"a"', serverAt: 100), SyncStep.send);
      expect(step('"a"', '"c"'), SyncStep.take);
    });

    test("changed on both: the newer wins, ours doesn't overwrite a newer one", () {
      expect(step('"b"', '"c"', serverAt: 300, localAt: 250), SyncStep.take);
      expect(step('"b"', '"c"', serverAt: 300, localAt: 350), SyncStep.send);
    });

    test('changed on both, a set of things: put together', () {
      expect(step('"b"', '"c"', merge: true), SyncStep.merge);
    });

    test('the first time on this device: the other devices win, but a set of things keeps both', () {
      SyncStep first({bool merge = false}) =>
          syncStep(local: '{"e1":1}', last: null, lastAt: 0, server: '{"e2":2}', serverAt: 200, mergeable: merge);
      expect(first(), SyncStep.take);
      expect(first(merge: true), SyncStep.merge);
      expect(mergeSynced(null, {'e1': 1}, {'e2': 2}), {'e2': 2, 'e1': 1});
    });
  });

  group('putting both sides together', () {
    test('episodes played on two devices: both kept', () {
      final base = {'e1': 1};
      expect(mergeSynced(base, {'e1': 1, 'e2': 2}, {'e1': 1, 'e3': 3}), {'e1': 1, 'e2': 2, 'e3': 3});
    });

    test('removed on one side, added on the other', () {
      expect(mergeSynced({'a': 1, 'b': 2}, {'a': 1}, {'a': 1, 'b': 2, 'c': 3}), {'a': 1, 'c': 3});
    });

    test('artists followed: lists of things by id', () {
      final base = [
        {'id': 'x', 'name': 'X'},
      ];
      final here = [
        ...base,
        {'id': 'y', 'name': 'Y'},
      ];
      final there = <Map<String, Object>>[
        {'id': 'z', 'name': 'Z'},
      ]; // unfollowed X there, followed Z
      expect(mergeSynced(base, here, there), [
        {'id': 'z', 'name': 'Z'},
        {'id': 'y', 'name': 'Y'},
      ]);
    });

    test('"not for me": songs and artists from both', () {
      final base = {'songs': [], 'artists': ['A']};
      final here = {'songs': [], 'artists': ['A', 'B']};
      final there = {
        'songs': [
          {'id': 's1', 'title': 'T', 'artist': 'R'},
        ],
        'artists': ['A'],
      };
      expect(mergeSynced(base, here, there), {
        'songs': [
          {'id': 's1', 'title': 'T', 'artist': 'R'},
        ],
        'artists': ['A', 'B'],
      });
    });

    test('the same thing changed on both: the newer side wins', () {
      expect(mergeSynced({'s': 'old'}, {'s': 'mine'}, {'s': 'theirs'}, preferLocal: false), {'s': 'theirs'});
      expect(mergeSynced({'s': 'old'}, {'s': 'mine'}, {'s': 'theirs'}), {'s': 'mine'});
    });
  });
}
