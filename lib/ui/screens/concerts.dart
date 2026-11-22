import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/concerts.dart';
import '../../data/shows.dart';
import '../../data/updates.dart' show openUrl;
import '../actions.dart' show toast;
import '../widgets.dart';

/// Concerts near you, on Home: the next shows of the artists you play and follow, near your town.
class ConcertsShelf extends ConsumerWidget {
  const ConcertsShelf({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(concertsProvider).value;
    if (c == null || !c.supported || c.shows.isEmpty) return const SizedBox.shrink();
    return Shelf(
      title: 'Marquee',
      subtitle: c.city.isEmpty ? 'Concerts near you · set your town under Following › Shows' : 'Concerts in ${c.city}, from artists you play',
      textHeight: 76,
      onMore: () => context.push('/concerts'),
      children: [for (final (s, _) in c.shows.take(12)) ConcertCard(s)],
    );
  }
}

class ConcertCard extends StatelessWidget {
  const ConcertCard(this.show, {super.key});
  final Show show;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final d = DateTime.tryParse(show.date);
    const months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
    return SizedBox(
      width: AppLook.of(context).cardWidth,
      child: Tappable(
        onTap: () => showConcertSheet(context, show),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [cs.primaryContainer, cs.tertiaryContainer],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(d == null ? '' : months[d.month - 1],
                          style: t.titleSmall?.copyWith(color: cs.onPrimaryContainer, letterSpacing: 2)),
                      Text(d == null ? show.date : '${d.day}',
                          style: t.displayMedium?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(show.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
            Text(
              [show.city, show.venue].where((x) => x.isNotEmpty).join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// A show: tickets and "add to calendar".
Future<void> showConcertSheet(BuildContext context, Show s) => showModalBottomSheet(
  context: context,
  useRootNavigator: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (ctx) {
    final t = Theme.of(ctx).textTheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: Text(s.artist, style: t.titleLarge),
            subtitle: Text([
              '${showDate(s.date)}${s.time.isEmpty ? '' : ', ${s.time}'}',
              if (s.name.isNotEmpty && s.name != s.artist) s.name,
              if (s.place.isNotEmpty) s.place,
            ].join('\n')),
            isThreeLine: true,
          ),
          if (s.url.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.confirmation_number_outlined),
              title: Text(s.source == 'Ticketmaster' ? 'Tickets' : 'More about it'),
              subtitle: Text(s.source),
              onTap: () {
                Navigator.pop(ctx);
                openUrl(s.url);
              },
            ),
          ListTile(
            leading: const Icon(Icons.event_available_outlined),
            title: const Text('Add to calendar'),
            onTap: () async {
              Navigator.pop(ctx);
              try {
                await addShowToCalendar(s);
              } catch (e) {
                if (context.mounted) toast(context, 'Couldn\'t open your calendar: $e');
              }
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  },
);

/// Every concert near you, by month.
class ConcertsScreen extends ConsumerWidget {
  const ConcertsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(concertsProvider);
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Marquee · Concerts near you')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(concertsProvider),
        child: AsyncView(r, (Concerts c) {
          if (!c.supported) {
            return const Center(child: Text('Your server can\'t look for concerts (it needs Conductor or music-lookup)'));
          }
          // the month of each show that starts a new month (a heading goes above it)
          final starts = <int>{};
          String? month;
          for (final (i, (s, _)) in c.shows.indexed) {
            final m = s.date.length >= 7 ? s.date.substring(0, 7) : null;
            if (m != null && m != month) starts.add(i);
            month = m ?? month;
          }
          return ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.place_outlined),
                title: Text(c.city.isEmpty ? 'Anywhere: set your town' : 'Near ${c.city}'),
                subtitle: Text(c.source == 'Ticketmaster'
                    ? 'From Ticketmaster · checked once a week'
                    : 'From MusicBrainz · add a Ticketmaster key for more shows and tickets'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/following?tab=2'),
              ),
              if (c.shows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No concerts found near you yet. They\'re checked once a week.')),
                ),
              for (final (i, (s, _)) in c.shows.indexed) ...[
                if (starts.contains(i))
                  SectionTitle(showDate('${s.date.substring(0, 7)}-01').split(' ').skip(2).join(' ')),
                ListTile(
                  leading: SizedBox(
                    width: 44,
                    child: Text(showDate(s.date).split(' ').take(2).join('\n'),
                        textAlign: TextAlign.center, style: t.labelLarge?.copyWith(color: cs.primary)),
                  ),
                  title: Text(s.artist),
                  subtitle: Text(s.place, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => showConcertSheet(context, s),
                ),
              ],
            ],
          );
        }, onRetry: () => ref.invalidate(concertsProvider)),
      ),
    );
  }
}
