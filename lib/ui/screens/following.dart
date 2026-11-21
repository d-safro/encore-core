import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/appearance.dart';
import '../../core/settings.dart';
import '../../data/follows.dart';
import '../../data/shows.dart';
import '../../data/updates.dart' show openUrl;
import '../../data/episode_alerts.dart' show askNotificationPermission, releaseAlertsOn;
import '../actions.dart' show askText, toast;
import '../widgets.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "5 Dec 2026", "Fri 5 Dec" for dates soon, or just the year / month when that's all that's known.
String niceDate(String date, {DateTime? now}) {
  now ??= DateTime.now();
  final d = DateTime.tryParse(date);
  if (d == null) {
    final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(date);
    return m == null ? date : '${_months[int.parse(m[2]!) - 1]} ${m[1]}';
  }
  final today = DateTime(now.year, now.month, now.day);
  final diff = d.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  final short = '${d.day} ${_months[d.month - 1]}';
  if (diff > 0 && diff < 7) return '${_days[d.weekday - 1]} $short';
  return d.year == now.year ? short : '$short ${d.year}';
}

String _kind(String type) => switch (type) {
  'ep' => 'EP',
  'single' => 'Single',
  _ => 'Album',
};

/// One release as a card, like an album card. Upcoming ones say when they come out.
class ReleaseCard extends StatelessWidget {
  const ReleaseCard(this.r, {super.key, this.width});
  final Release r;
  final double? width;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final soon = r.upcoming(DateTime.now());
    return SizedBox(
      width: width ?? AppLook.of(context).cardWidth,
      child: Tappable(
        onTap: () => context.push(r.route),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Cover(r.cover, size: double.infinity, radius: 14, artist: r.artist, album: r.title),
                ),
                if (r.ownId.isEmpty)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: soon ? cs.primary : cs.surface.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        soon ? 'Soon' : '⬇',
                        style: t.labelSmall?.copyWith(color: soon ? cs.onPrimary : cs.onSurface),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
            Text(
              '${r.artist} · ${_kind(r.type)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            Text(
              soon ? 'Out ${niceDate(r.date)}' : niceDate(r.date),
              maxLines: 1,
              style: t.bodySmall?.copyWith(color: soon ? cs.primary : cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Home: the newest releases from artists you follow. Hidden when there are none.
class NewReleasesShelf extends ConsumerWidget {
  const NewReleasesShelf({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(releasesProvider);
    if (l.isEmpty) return const SizedBox.shrink();
    final now = DateTime.now();
    // what's coming soonest first, then what's newest
    final soon = l.where((r) => r.upcoming(now)).toList().reversed;
    final out = l.where((r) => !r.upcoming(now));
    return Shelf(
      title: 'New releases',
      subtitle: 'From artists you follow',
      textHeight: 76,
      onMore: () => context.push('/following?tab=1'),
      children: [for (final r in [...soon, ...out].take(12)) ReleaseCard(r)],
    );
  }
}

/// Followed artists, their releases and their shows, in three tabs.
class FollowingScreen extends StatelessWidget {
  const FollowingScreen({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    initialIndex: initialTab.clamp(0, 2),
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Following'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Artists'),
            Tab(text: 'New releases'),
            Tab(text: 'Shows'),
          ],
        ),
      ),
      body: const TabBarView(children: [_ArtistsTab(), _ReleasesTab(), _ShowsTab()]),
    ),
  );
}

class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = [...ref.watch(followsProvider)]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (l.isEmpty) {
      return const _Empty(
        Icons.person_add_alt_1_rounded,
        'No one yet',
        'Tap Follow on an artist\'s page to see their new releases and shows here.',
      );
    }
    return ListView(
      children: [
        for (final a in l)
          ListTile(
            leading: Cover(a.cover, size: 48, circle: true, icon: Icons.person, artist: a.name, artistImage: a.cover.isEmpty),
            title: Text(a.name),
            onTap: () => context.push('/artist/${a.id}'),
            trailing: TextButton(
              onPressed: () => ref.read(followsProvider.notifier).toggle(a),
              child: const Text('Unfollow'),
            ),
          ),
      ],
    );
  }
}

class _ReleasesTab extends ConsumerStatefulWidget {
  const _ReleasesTab();
  @override
  ConsumerState<_ReleasesTab> createState() => _ReleasesTabState();
}

class _ReleasesTabState extends ConsumerState<_ReleasesTab> {
  @override
  Widget build(BuildContext context) {
    final l = ref.watch(releasesProvider);
    final follows = ref.watch(followsProvider);
    final now = DateTime.now();
    final soon = l.where((r) => r.upcoming(now)).toList().reversed.toList();
    final out = l.where((r) => !r.upcoming(now)).toList();
    final cs = Theme.of(context).colorScheme;
    Widget tile(Release r) => ListTile(
      leading: Cover(r.cover, size: 52, artist: r.artist, album: r.title),
      title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${r.artist} · ${_kind(r.type)} · ${niceDate(r.date)}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: r.ownId.isNotEmpty
          ? Icon(Icons.library_music_rounded, size: 18, color: cs.primary)
          : (r.upcoming(now) ? null : const Text('⬇')),
      onTap: () => context.push(r.route),
    );
    return RefreshIndicator(
      onRefresh: () => ref.read(releasesProvider.notifier).refresh(force: true),
      child: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('Tell me about new releases'),
            subtitle: const Text('A notification on the day something comes out (checked once a day)'),
            value: releaseAlertsOn(prefs),
            onChanged: (v) async {
              await prefs.setBool('releaseAlerts', v);
              if (v) await askNotificationPermission(prefs);
              setState(() {});
            },
          ),
          if (follows.isEmpty)
            const _Empty(Icons.new_releases_outlined, 'Follow some artists', 'Their albums, EPs and singles show up here.')
          else if (l.isEmpty)
            const _Empty(
              Icons.new_releases_outlined,
              'Nothing new lately',
              'Nothing in the last four months, or the first check is still running. Pull down to check again.',
            ),
          if (soon.isNotEmpty) const SectionTitle('Coming soon'),
          for (final r in soon) tile(r),
          if (out.isNotEmpty) const SectionTitle('Out now', subtitle: 'The last four months'),
          for (final r in out) tile(r),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Dates from MusicBrainz, with Deezer. ⬇ albums aren\'t in your library: open one to get it.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// A list of shows with the "near me" filter; used for everyone you follow and on an artist's page.
class ShowTile extends StatelessWidget {
  const ShowTile(this.s, {super.key, this.showArtist = true});
  final Show s;
  final bool showArtist;
  @override
  Widget build(BuildContext context) {
    final d = DateTime.tryParse(s.date);
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return ListTile(
      leading: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(d == null ? '' : _months[d.month - 1].toUpperCase(), style: t.labelSmall?.copyWith(color: cs.primary)),
            Text(d == null ? '?' : '${d.day}', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
      ),
      title: Text(showArtist ? s.artist : (s.city.isNotEmpty ? s.city : s.name), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [niceDate(s.date), if (s.time.isNotEmpty) s.time, if (s.place.isNotEmpty) s.place else s.name].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: s.url.isEmpty
          ? null
          : IconButton(
              tooltip: s.source == 'Ticketmaster' ? 'Tickets' : 'Details',
              icon: Icon(s.source == 'Ticketmaster' ? Icons.confirmation_number_outlined : Icons.open_in_new_rounded),
              onPressed: () => openUrl(s.url).catchError((_) {}),
            ),
      onTap: s.url.isEmpty ? null : () => openUrl(s.url).catchError((_) {}),
    );
  }
}

/// The town for "near me": typed in, so Encore never needs your location.
class NearMeField extends ConsumerStatefulWidget {
  const NearMeField({super.key});
  @override
  ConsumerState<NearMeField> createState() => _NearMeFieldState();
}

class _NearMeFieldState extends ConsumerState<NearMeField> {
  late final _ctl = TextEditingController(text: ref.read(showsPrefsProvider).city);
  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: TextField(
      controller: _ctl,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.place_outlined),
        labelText: 'Near me',
        hintText: 'A city, state or country (empty: everywhere)',
        suffixIcon: _ctl.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _ctl.clear();
                  ref.read(showsPrefsProvider.notifier).set(city: '');
                },
              ),
      ),
      onChanged: (v) => ref.read(showsPrefsProvider.notifier).set(city: v),
    ),
  );
}

Future<void> editTicketmasterKey(BuildContext context, WidgetRef ref) async {
  final v = await askText(
    context,
    'Ticketmaster key',
    'Consumer key from developer.ticketmaster.com',
    initial: ref.read(showsPrefsProvider).tmKey,
  );
  if (v == null) return;
  ref.read(showsPrefsProvider.notifier).set(tmKey: v);
  if (context.mounted) toast(context, v.isEmpty ? 'Using MusicBrainz for shows' : 'Using Ticketmaster for shows');
}

class _ShowsTab extends ConsumerWidget {
  const _ShowsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(showsPrefsProvider);
    final follows = ref.watch(followsProvider);
    final all = ref.watch(followedShowsProvider);
    final (got, done) = all.value ?? (const <Show>[], false);
    final list = got.where((s) => s.near(p.city)).toList();
    final cs = Theme.of(context).colorScheme;
    final loading = !done && !all.hasError;
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(followedShowsProvider),
      child: ListView(
        children: [
          const NearMeField(),
          ListTile(
            dense: true,
            leading: const Icon(Icons.key_outlined),
            title: Text(p.tmKey.isEmpty ? 'Add a Ticketmaster key for more shows and ticket links' : 'Shows from Ticketmaster'),
            subtitle: Text(p.tmKey.isEmpty ? 'Free at developer.ticketmaster.com. Now: MusicBrainz events' : 'Tap to change the key'),
            onTap: () => editTicketmasterKey(context, ref),
          ),
          if (follows.isEmpty)
            const _Empty(Icons.event_outlined, 'Follow some artists', 'Their next concerts show up here.')
          else if (list.isEmpty && !loading)
            _Empty(
              Icons.event_busy_outlined,
              'No shows found',
              p.city.isEmpty ? 'None announced for the artists you follow.' : 'None near "${p.city}". Clear the box to see all.',
            ),
          for (final s in list) ShowTile(s),
          if (loading && follows.isNotEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Shows are checked once a day.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.icon, this.title, this.text);
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
      child: Column(
        children: [
          Icon(icon, size: 48, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(text, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}
