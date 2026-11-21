import 'dart:async';
import '../../core/platform.dart';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../../core/settings.dart';
import '../../data/account.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../data/subsonic.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../state.dart';
import '../widgets.dart';

// ── Data (the last answers are kept on the phone, for when the server can't be reached) ──
Object? _cached(String key) {
  try {
    final m = jsonDecode(prefs.getString('podcastCache') ?? '{}') as Map<String, dynamic>;
    return m[key];
  } catch (_) {
    return null;
  }
}

void _cache(String key, Object value) {
  Map<String, dynamic> m;
  try {
    m = jsonDecode(prefs.getString('podcastCache') ?? '{}') as Map<String, dynamic>;
  } catch (_) {
    m = {};
  }
  m[key] = value;
  prefs.setString('podcastCache', jsonEncode(m));
}

/// A show with its newest 150 episodes (enough offline; keeps the phone's copy small).
void _cacheShow(PodcastChannel p) {
  final j = p.toJson();
  j['episode'] = (j['episode'] as List).take(150).toList();
  _cache('ch:${p.id}', j);
}

/// While connected: keep the phone's copy of your shows and their latest episodes, for offline use.
Future<void> warmPodcastCache(SubsonicClient c) async {
  try {
    final l = await c.podcasts();
    _cache('list', [for (final p in l) p.toJson()]);
    for (final p in l) {
      final full = await c.podcast(p.id);
      if (full != null) _cacheShow(full);
    }
  } catch (_) {}
}

List<PodcastChannel> _cachedList(String key) => [
  for (final e in (_cached(key) as List?) ?? const [])
    if (e is Map) PodcastChannel.fromJson(e.cast<String, dynamic>()),
];

final podcastsProvider = FutureProvider.autoDispose<List<PodcastChannel>>((ref) async {
  final c = ref.watch(clientProvider);
  if (c == null || !ref.watch(repoProvider).online) return _cachedList('list');
  try {
    final l = await c.podcasts();
    _cache('list', [for (final p in l) p.toJson()]);
    return l;
  } catch (_) {
    return _cachedList('list');
  }
});

final podcastProvider = FutureProvider.autoDispose.family<PodcastChannel?, String>((ref, id) async {
  PodcastChannel? fromCache() {
    final j = _cached('ch:$id');
    return j is Map ? PodcastChannel.fromJson(j.cast<String, dynamic>()) : null;
  }

  final c = ref.watch(clientProvider);
  if (c == null || !ref.watch(repoProvider).online) return fromCache();
  try {
    final p = await c.podcast(id);
    if (p != null) _cacheShow(p);
    return p;
  } catch (_) {
    return fromCache();
  }
});

final newestEpisodesProvider = FutureProvider.autoDispose<List<PodcastEpisode>>((ref) async {
  List<PodcastEpisode> fromCache() => [
    for (final e in (_cached('newest') as List?) ?? const [])
      if (e is Map) PodcastEpisode.fromJson(e.cast<String, dynamic>()),
  ];
  final c = ref.watch(clientProvider);
  if (c == null || !ref.watch(repoProvider).online) return fromCache();
  try {
    final l = await c.newestEpisodes(count: 12);
    _cache('newest', [for (final e in l) e.toJson()]);
    return l;
  } catch (_) {
    return fromCache(); // away, or a server without podcast support
  }
});

void refreshPodcastViews(WidgetRef ref, [String? channelId]) {
  ref.invalidate(podcastsProvider);
  ref.invalidate(newestEpisodesProvider);
  if (channelId != null) ref.invalidate(podcastProvider(channelId));
}

/// The podcaster page for a show's maker: [name] when known, otherwise worked out from the show.
String podcasterPath({String name = '', String show = ''}) => Uri(
  path: '/podcaster',
  queryParameters: {if (name.isNotEmpty) 'name': name, if (show.isNotEmpty) 'show': show},
).toString();

/// Follows a show on your server by its feed address. True when it worked.
Future<bool> followPodcast(BuildContext context, WidgetRef ref, String url, String name) async {
  final c = ref.read(clientProvider);
  if (c == null) return false;
  try {
    await c.subscribePodcast(url);
    refreshPodcastViews(ref);
    if (context.mounted) toast(context, 'Following $name. New episodes download to your server.');
    return true;
  } catch (e) {
    if (context.mounted) toast(context, "Couldn't add it: $e");
    return false;
  }
}

String _ago(DateTime? d) {
  if (d == null) return '';
  final days = DateTime.now().difference(d).inDays;
  if (days < 1) return 'Today';
  if (days < 2) return 'Yesterday';
  if (days < 7) return '$days days ago';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${m[d.month - 1]} ${d.day}${d.year != DateTime.now().year ? ', ${d.year}' : ''}';
}

String _length(int seconds) {
  if (seconds <= 0) return '';
  final h = seconds ~/ 3600, min = (seconds % 3600) ~/ 60;
  return h > 0 ? '$h h ${min.toString().padLeft(2, '0')} min' : '${(seconds / 60).round()} min';
}

// ── Library tab ──
class PodcastsTab extends ConsumerWidget {
  const PodcastsTab({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(repoProvider).online;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      floatingActionButton: online
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('Add podcast'),
              onPressed: () => context.push('/podcasts/add'),
            )
          : null,
      body: AsyncView(ref.watch(podcastsProvider), (List<PodcastChannel> list) {
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                online
                    ? 'No podcasts yet. Tap Add podcast to find one.'
                    : "Can't reach your server. Your shows appear here once the app has seen them online.",
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            try {
              await ref.read(clientProvider)?.refreshPodcasts();
            } catch (_) {}
            await Future.delayed(const Duration(seconds: 2));
            refreshPodcastViews(ref);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              for (final p in list)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: Cover(p.coverArt, size: 56, radius: 10, icon: Icons.podcasts_rounded),
                  title: Text(p.title, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    [if (p.author.isNotEmpty) p.author, if (p.latest != null) 'Latest: ${_ago(p.latest)}'].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: p.unplayed > 0
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(999)),
                          child: Text(
                            p.unplayed > 99 ? '99+' : '${p.unplayed}',
                            style: t.labelSmall?.copyWith(color: cs.onPrimary, fontWeight: FontWeight.w700),
                          ),
                        )
                      : null,
                  onTap: () => context.push('/podcast/${p.id}'),
                ),
            ],
          ),
        );
      }, onRetry: () => ref.invalidate(podcastsProvider)),
    );
  }
}

// ── A show ──
class PodcastScreen extends ConsumerStatefulWidget {
  const PodcastScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PodcastScreen> createState() => _PodcastScreenState();
}

class _PodcastScreenState extends ConsumerState<PodcastScreen> {
  bool _aboutOpen = false, _hidePlayed = false;
  int _shown = 50;

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(podcastProvider(widget.id));
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (p.value != null)
            PopupMenuButton<String>(
              onSelected: (v) async {
                final c = ref.read(clientProvider);
                final ch = p.value!;
                if (c == null) return;
                try {
                  if (v == 'unsubscribe') {
                    if (!await confirm(
                      context,
                      'Unfollow ${ch.title}?',
                      'Its episodes on your server are deleted.',
                      ok: 'Unfollow',
                    )) {
                      return;
                    }
                    await c.unsubscribePodcast(ch.id);
                    refreshPodcastViews(ref);
                    if (context.mounted) context.pop();
                  } else if (v == 'refresh') {
                    await c.refreshPodcasts();
                    await Future.delayed(const Duration(seconds: 3));
                    refreshPodcastViews(ref, ch.id);
                  }
                } catch (e) {
                  if (context.mounted) toast(context, "Couldn't do that: $e");
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'refresh', child: Text('Check for new episodes')),
                PopupMenuItem(value: 'unsubscribe', child: Text('Unfollow')),
              ],
            ),
        ],
      ),
      body: AsyncView(p, (PodcastChannel? ch) {
        if (ch == null) return const Center(child: Text('This podcast needs your server'));
        final eps = ch.episodes.where((e) => !_hidePlayed || !e.played).toList();
        final resume = ch.episodes.where((e) => e.inProgress).firstOrNull;
        final next = resume ?? ch.episodes.where((e) => !e.played).firstOrNull;
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(podcastProvider(widget.id)),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Cover(ch.coverArt, size: 120, radius: 14, icon: Icons.podcasts_rounded),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(ch.title, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                          if (ch.author.isNotEmpty)
                            // its own button for screen readers ("About …"), not read as part of the header
                            Semantics(
                              container: true,
                              button: true,
                              label: 'About ${ch.author}',
                              excludeSemantics: true,
                              onTap: () => context.push(podcasterPath(name: ch.author, show: ch.id)),
                              // a link like every other name: underlined when pointed at, no gray box
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: NameLink(
                                        ch.author,
                                        phoneToo: true,
                                        onTap: () => context.push(podcasterPath(name: ch.author, show: ch.id)),
                                        style: t.bodyMedium?.copyWith(color: cs.primary, fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    Icon(Icons.chevron_right_rounded, size: 18, color: cs.primary),
                                  ],
                                ),
                              ),
                            ),
                          const SizedBox(height: 4),
                          Text(
                            [
                              plural(
                                ch.episodeCount > ch.episodes.length ? ch.episodeCount : ch.episodes.length,
                                'episode',
                              ),
                              if (ch.unplayed > 0) '${ch.unplayed} new',
                            ].join(' · '),
                            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          if (ch.error.isNotEmpty)
                            Text("Couldn't check for new episodes", style: t.bodySmall?.copyWith(color: cs.error)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (next != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(
                      resume != null ? 'Resume: ${resume.title}' : 'Play latest: ${next.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () => audioHandler.playEpisode(next),
                  ),
                ),
              if (ch.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: InkWell(
                    onTap: () => setState(() => _aboutOpen = !_aboutOpen),
                    child: Text(
                      ch.description,
                      maxLines: _aboutOpen ? null : 3,
                      overflow: _aboutOpen ? null : TextOverflow.ellipsis,
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    Text('Episodes', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    FilterChip(
                      label: const Text('Hide played'),
                      selected: _hidePlayed,
                      onSelected: (v) => setState(() => _hidePlayed = v),
                    ),
                  ],
                ),
              ),
              for (final e in eps.take(_shown)) EpisodeTile(e),
              if (eps.length > _shown)
                Center(
                  child: TextButton(
                    onPressed: () => setState(() => _shown += 100),
                    child: Text('Show more (${eps.length - _shown} older)'),
                  ),
                ),
            ],
          ),
        );
      }, onRetry: () => ref.invalidate(podcastProvider(widget.id))),
    );
  }
}

class EpisodeTile extends ConsumerWidget {
  const EpisodeTile(this.e, {super.key, this.showCover = false});
  final PodcastEpisode e;
  final bool showCover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final playing = ref.watch(mediaItemProvider.select((m) => m.value?.id == e.id));
    final (progress, onPhone) = ref.watch(
      downloadsProvider.select((d) => (d.progress[e.id], d.files.containsKey(e.id))),
    );
    final offline = ref.watch(offlineProvider);
    final left = e.inProgress && e.duration > 0 ? e.duration - e.position ~/ 1000 : null;
    return InkWell(
      onTap: () => offline && !onPhone
          ? toast(context, "This episode isn't downloaded, and your server can't be reached")
          : audioHandler.playEpisode(e),
      onSecondaryTap: () => showEpisodeMenu(context, ref, e),
      onLongPress: () => showEpisodeMenu(context, ref, e),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showCover)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Cover(e.coverArt, size: 52, radius: 8, icon: Icons.podcasts_rounded),
              ),
            Expanded(
              child: Opacity(
                opacity: e.played || (offline && !onPhone) ? 0.55 : 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: _ago(e.published)),
                          if (showCover && e.show.isNotEmpty) ...[
                            if (e.published != null) const TextSpan(text: ' · '),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: Tappable(
                                onTap: () => context.push(podcasterPath(name: e.author, show: e.channelId)),
                                child: Text(
                                  e.show,
                                  style: t.labelSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyLarge?.copyWith(fontWeight: FontWeight.w600, color: playing ? cs.primary : null),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (e.played)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(Icons.check_circle_rounded, size: 14, color: cs.primary),
                          ),
                        if (onPhone)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(Icons.arrow_circle_down_rounded, size: 14, color: cs.primary),
                          ),
                        Text(
                          e.played
                              ? 'Played'
                              : left != null
                              ? '${_length(left)} left'
                              : _length(e.duration),
                          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        if (e.inProgress && e.duration > 0) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 60,
                            child: LinearProgressIndicator(
                              value: (e.position / 1000 / e.duration).clamp(0, 1).toDouble(),
                              minHeight: 3,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                        if (progress != null) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, value: progress > 0 ? progress : null),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              icon: Icon(playing ? Icons.graphic_eq_rounded : Icons.play_circle_outline_rounded, color: cs.primary),
              onPressed: () => audioHandler.playEpisode(e),
            ),
            IconButton(icon: const Icon(Icons.more_vert), onPressed: () => showEpisodeMenu(context, ref, e)),
          ],
        ),
      ),
    );
  }
}

Future<void> showEpisodeMenu(BuildContext context, WidgetRef ref, PodcastEpisode e) async {
  final dl = ref.read(downloadsProvider);
  final onPhone = dl.files.containsKey(e.id);
  await showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      Future<void> act(Future<void> Function() f, [String? done]) async {
        Navigator.pop(ctx);
        try {
          await f();
          refreshPodcastViews(ref, e.channelId);
          if (done != null && context.mounted) toast(context, done);
        } catch (err) {
          if (context.mounted) toast(context, "Couldn't do that: $err");
        }
      }

      final c = ref.read(clientProvider);
      final atPath = GoRouter.of(context).routerDelegate.currentConfiguration.uri.path;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(e.show),
              ),
              const Divider(height: 1),
              if (e.channelId.isNotEmpty && atPath != '/podcast/${e.channelId}')
                ListTile(
                  leading: const Icon(Icons.podcasts_rounded),
                  title: const Text('Go to show'),
                  onTap: () {
                    Navigator.pop(ctx);
                    context.push('/podcast/${e.channelId}');
                  },
                ),
              if (e.author.isNotEmpty || e.channelId.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(e.author.isNotEmpty ? 'About ${e.author}' : 'About the show'),
                  onTap: () {
                    Navigator.pop(ctx);
                    context.push(podcasterPath(name: e.author, show: e.channelId));
                  },
                ),
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: Text(e.inProgress ? 'Resume' : 'Play'),
                onTap: () => act(() => audioHandler.playEpisode(e)),
              ),
              if (e.inProgress)
                ListTile(
                  leading: const Icon(Icons.replay_rounded),
                  title: const Text('Play from the start'),
                  onTap: () => act(() => audioHandler.playSongs([e.toSong()])),
                ),
              ListTile(
                leading: const Icon(Icons.playlist_add_rounded),
                title: const Text('Play next'),
                onTap: () => act(() => audioHandler.playNext([e.toSong()]), 'Plays next'),
              ),
              if (c != null)
                ListTile(
                  leading: Icon(e.played ? Icons.radio_button_unchecked : Icons.check_circle_outline_rounded),
                  title: Text(e.played ? 'Mark as not played' : 'Mark as played'),
                  onTap: () => act(() => c.podcastProgress(e.id, played: !e.played)),
                ),
              if (c != null)
                ListTile(
                  leading: Icon(e.downloaded ? Icons.cloud_off_outlined : Icons.cloud_download_outlined),
                  title: Text(e.downloaded ? 'Remove from your server' : 'Save on your server'),
                  subtitle: Text(
                    e.downloaded ? 'It will stream from the podcast again' : 'Kept even if the podcast removes it',
                  ),
                  onTap: () => act(
                    () => c.keepEpisodeOnServer(e.id, !e.downloaded),
                    e.downloaded ? 'Removed from your server' : 'Saving on your server',
                  ),
                ),
              ListTile(
                leading: Icon(onPhone ? Icons.delete_outline : Icons.download_rounded),
                title: Text(onPhone ? 'Remove from $deviceWord' : 'Download to $deviceWord'),
                onTap: () => act(
                  () => onPhone
                      ? ref.read(downloadsProvider.notifier).remove([e.id])
                      : ref.read(downloadsProvider.notifier).download([e.toSong()], manual: true),
                  onPhone ? 'Removed from the $deviceWord' : 'Downloading',
                ),
              ),
              if (e.description.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.notes_rounded),
                  title: const Text('Show notes'),
                  onTap: () {
                    Navigator.pop(ctx);
                    showDialog(
                      context: context,
                      builder: (d) => AlertDialog(
                        title: Text(e.title),
                        content: SingleChildScrollView(child: SelectableText(e.description)),
                        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close'))],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      );
    },
  );
}

// ── Finding podcasts (Apple's public podcast directory; only the search words are sent) ──
class AddPodcastScreen extends ConsumerStatefulWidget {
  const AddPodcastScreen({super.key});
  @override
  ConsumerState<AddPodcastScreen> createState() => _AddPodcastScreenState();
}

class _AddPodcastScreenState extends ConsumerState<AddPodcastScreen> {
  final _ctl = TextEditingController();
  Timer? _debounce;
  Future<List<Map<String, dynamic>>>? _results;
  final _adding = <String>{}, _added = <String>{};

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  static Future<List<Map<String, dynamic>>> _search(String q) async {
    final r = await http
        .get(
          Uri.https('itunes.apple.com', '/search', {'media': 'podcast', 'limit': '25', 'term': q}),
          headers: {'User-Agent': 'Encore music player'},
        )
        .timeout(const Duration(seconds: 10));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final list = j is Map && j['results'] is List ? j['results'] as List : const [];
    return [
      for (final e in list)
        if (e is Map && '${e['feedUrl'] ?? ''}'.startsWith('http')) e.cast<String, dynamic>(),
    ];
  }

  Future<void> _add(String url, String name) async {
    setState(() => _adding.add(url));
    final ok = await followPodcast(context, ref, url, name);
    if (mounted) setState(() => _adding.remove(url));
    if (ok && mounted) setState(() => _added.add(url));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add podcast'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('Feed address'),
            onPressed: () async {
              final url = await askText(context, 'Podcast feed (RSS) address', 'https://…');
              if (url != null && url.trim().startsWith('http')) await _add(url.trim(), 'it');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchBar(
              controller: _ctl,
              hintText: 'Search podcasts',
              leading: const Icon(Icons.search),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: (q) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 450), () {
                  if (mounted) setState(() => _results = q.trim().length < 2 ? null : _search(q.trim()));
                });
              },
            ),
          ),
          Expanded(
            child: _results == null
                ? const Center(child: Text('Search by name or host'))
                : FutureBuilder<List<Map<String, dynamic>>>(
                    future: _results,
                    builder: (_, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snap.hasError) return const Center(child: Text("Couldn't search right now"));
                      final list = snap.data ?? const [];
                      if (list.isEmpty) return const Center(child: Text('Nothing found'));
                      return ListView(
                        children: [
                          for (final p in list)
                            ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  '${p['artworkUrl100'] ?? ''}',
                                  width: 52,
                                  height: 52,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const SizedBox(width: 52, height: 52, child: Icon(Icons.podcasts_rounded)),
                                ),
                              ),
                              title: Text('${p['collectionName'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                [
                                  '${p['artistName'] ?? ''}',
                                  if (p['trackCount'] != null) '${p['trackCount']} episodes',
                                ].where((x) => x.isNotEmpty).join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                              ),
                              trailing: _added.contains(p['feedUrl'])
                                  ? Icon(Icons.check_circle, color: cs.primary)
                                  : _adding.contains(p['feedUrl'])
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : IconButton(
                                      tooltip: 'Follow',
                                      icon: const Icon(Icons.add_circle_outline),
                                      onPressed: () => _add('${p['feedUrl']}', '${p['collectionName'] ?? 'it'}'),
                                    ),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Home shelf: the newest episodes of the shows you follow.
class NewEpisodesShelf extends ConsumerWidget {
  const NewEpisodesShelf({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eps = (ref.watch(newestEpisodesProvider).value ?? const <PodcastEpisode>[]).where((e) => !e.played).toList();
    if (eps.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle('New episodes', onMore: () => context.go('/library?tab=1')),
        for (final e in eps.take(4)) EpisodeTile(e, showCover: true),
      ],
    );
  }
}
