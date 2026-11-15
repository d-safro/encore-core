import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/account.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../playback/handler.dart';
import '../widgets.dart';

/// (period, offset) → your listening for it.
final statsProvider = FutureProvider.autoDispose.family<ListeningStats, (String, int)>((ref, k) async {
  ref.cacheFor(const Duration(minutes: 5));
  final c = ref.watch(clientProvider);
  if (c == null || !ref.watch(repoProvider).online) throw Exception('Stats need your server');
  return c.listeningStats(k.$1, offset: k.$2);
});

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Your listening: minutes, plays, top artists / songs / albums, and when you listen.
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});
  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  String _period = 'month';
  int _offset = 0;

  String _label(ListeningStats? s) {
    if (_period == 'all') return 'All time';
    final f = s?.from;
    if (_offset == 0) return switch (_period) { 'week' => 'This week', 'month' => 'This month', _ => 'This year' };
    if (_offset == 1) return switch (_period) { 'week' => 'Last week', 'month' => 'Last month', _ => 'Last year' };
    if (f == null) return '';
    return switch (_period) {
      'week' => 'Week of ${f.day} ${_months[f.month - 1]}',
      'month' => '${_months[f.month - 1]} ${f.year}',
      _ => '${f.year}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(statsProvider((_period, _offset)));
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Your listening')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(statsProvider((_period, _offset))),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'week', label: Text('Week')),
                  ButtonSegment(value: 'month', label: Text('Month')),
                  ButtonSegment(value: 'year', label: Text('Year')),
                  ButtonSegment(value: 'all', label: Text('All time')),
                ],
                selected: {_period},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() {
                  _period = v.first;
                  _offset = 0;
                }),
              ),
            ),
            if (_period != 'all')
              Row(
                children: [
                  IconButton(
                    tooltip: 'Earlier',
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: () => setState(() => _offset++),
                  ),
                  Expanded(child: Text(_label(stats.value), textAlign: TextAlign.center, style: t.titleMedium)),
                  IconButton(
                    tooltip: 'Later',
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: _offset == 0 ? null : () => setState(() => _offset--),
                  ),
                ],
              )
            else
              const SizedBox(height: 12),
            AsyncView(stats, (ListeningStats s) => _Body(s, period: _period), onRetry: () {
              ref.invalidate(statsProvider((_period, _offset)));
            }),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.s, {required this.period});
  final ListeningStats s;
  final String period;

  static String _hours(int minutes) => minutes < 120
      ? '$minutes min'
      : '${(minutes / 60).toStringAsFixed(minutes < 600 ? 1 : 0)} h';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    if (s.isEmpty) {
      final since = s.since;
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          since == null
              ? 'No plays recorded yet. Every song you finish (in any app on your server) counts from now on.'
              : 'No plays in this period. Plays are counted since ${since.day} ${_months[since.month - 1]} ${since.year}.',
          textAlign: TextAlign.center,
        ),
      );
    }
    final songs = [for (final (song, _) in s.songs) song];
    final countedFrom = s.since != null && s.from != null && s.since!.isAfter(s.from!) ? s.since : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // the headline numbers
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_hours(s.minutes), style: t.displaySmall?.copyWith(fontWeight: FontWeight.w800, color: cs.primary)),
                  Text('of music', style: t.bodyMedium),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 24,
                    runSpacing: 12,
                    children: [
                      _Num('${s.plays}', 'plays'),
                      _Num('${s.songCount}', 'songs'),
                      _Num('${s.artistCount}', 'artists'),
                      if (s.newArtists != null && countedFrom == null) _Num('${s.newArtists}', 'new artists'),
                    ],
                  ),
                  if (countedFrom != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Counted since ${countedFrom.day} ${_months[countedFrom.month - 1]}, when play history started',
                        style: t.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (s.days.isNotEmpty && period != 'all') ...[
          SectionTitle(period == 'year' ? 'Minutes by month' : 'Minutes by day'),
          _Bars(_series(s, period), height: 120),
        ],
        if (s.hours.any((h) => h > 0)) ...[
          SectionTitle('When you listen', subtitle: _whenText(s.hours)),
          _Bars([for (var h = 0; h < 24; h++) (h % 6 == 0 ? '${h}h' : '', s.hours[h])], height: 80),
        ],
        if (s.artists.isNotEmpty)
          Shelf(
            title: 'Top artists',
            height: 172,
            children: [
              for (final (a, plays, _) in s.artists.take(20))
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: a.id.isEmpty ? null : () => context.push('/artist/${a.id}'),
                  child: SizedBox(
                    width: 112,
                    child: Column(
                      children: [
                        Cover(a.coverArt, size: 104, circle: true, icon: Icons.person, artist: a.name, artistImage: true),
                        const SizedBox(height: 8),
                        Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
                        Text('$plays plays', style: t.bodySmall),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        if (songs.isNotEmpty) ...[
          SectionTitle(
            'Top songs',
            trailing: IconButton.filledTonal(
              tooltip: 'Play these',
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: () => audioHandler.playSongs(songs, source: 'stats:$period'),
            ),
          ),
          for (var i = 0; i < min(20, s.songs.length); i++)
            Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Text('${i + 1}', textAlign: TextAlign.right, style: t.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
                Expanded(
                  child: SongTile(
                    s.songs[i].$1,
                    list: songs,
                    index: i,
                    trailing: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text('${s.songs[i].$2}×', style: t.labelMedium),
                    ),
                  ),
                ),
              ],
            ),
        ],
        if (s.albums.isNotEmpty)
          Shelf(title: 'Top albums', children: [for (final (a, _) in s.albums.take(20)) AlbumCard(a)]),
      ],
    );
  }

  /// Bars for the chart: every day of the week / month, or every month of the year.
  static List<(String, int)> _series(ListeningStats s, String period) {
    final byDay = {for (final (d, m) in s.days) DateTime(d.year, d.month, d.day): m};
    final from = s.from, to = s.to;
    if (from == null || to == null) return [for (final (d, m) in s.days) ('${d.day}', m)];
    if (period == 'year') {
      final per = List.filled(12, 0);
      for (final e in byDay.entries) {
        per[e.key.month - 1] += e.value;
      }
      return [for (var m = 0; m < 12; m++) (_months[m].substring(0, 1), per[m])];
    }
    final out = <(String, int)>[];
    for (var d = DateTime(from.year, from.month, from.day); d.isBefore(to); d = DateTime(d.year, d.month, d.day + 1)) {
      final label = period == 'week' ? ['M', 'T', 'W', 'T', 'F', 'S', 'S'][d.weekday - 1] : (d.day % 5 == 1 ? '${d.day}' : '');
      out.add((label, byDay[d] ?? 0));
    }
    return out;
  }

  static String _whenText(List<int> hours) {
    int sum(int a, int b) => [for (var h = a; h < b; h++) hours[h]].fold(0, (x, y) => x + y);
    final parts = {
      'in the morning': sum(5, 12),
      'in the afternoon': sum(12, 17),
      'in the evening': sum(17, 22),
      'late at night': sum(22, 24) + sum(0, 5),
    };
    final best = parts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return 'Mostly ${best.key}';
  }
}

class _Num extends StatelessWidget {
  const _Num(this.value, this.label);
  final String value, label;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: t.titleLarge),
        Text(label, style: t.bodySmall),
      ],
    );
  }
}

/// A simple bar chart: one bar per (label, value).
class _Bars extends StatelessWidget {
  const _Bars(this.data, {required this.height});
  final List<(String, int)> data;
  final double height;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final top = data.map((e) => e.$2).fold(1, max);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: height + 18,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final (label, v) in data)
              Expanded(
                child: Tooltip(
                  message: '$v min',
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        height: max(2, height * v / top),
                        margin: const EdgeInsets.symmetric(horizontal: 1.5),
                        decoration: BoxDecoration(
                          color: v == 0 ? cs.surfaceContainerHighest : cs.primary.withValues(alpha: 0.4 + 0.6 * v / top),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      SizedBox(
                        height: 18,
                        child: Text(label, style: t.labelSmall, maxLines: 1, overflow: TextOverflow.visible),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
