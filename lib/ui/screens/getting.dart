import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/account.dart';
import '../../data/models.dart';
import '../../data/requests.dart';
import '../../data/subsonic.dart' show friendlyError;
import '../../playback/handler.dart';
import '../actions.dart';
import '../sheets.dart';
import '../widgets.dart';

/// "Getting your songs": what the server is getting for you (the ⬇ songs you played, hearted or added), as it goes:
/// on its way (with the download's progress), not found, and what arrived lately. An admin can act on each one.

/// When, for a person: "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago", "12 Nov".
String requestWhen(DateTime? d, [DateTime? now]) {
  if (d == null) return '';
  final n = now ?? DateTime.now();
  final s = n.difference(d);
  if (s.inMinutes < 1) return 'just now';
  if (s.inMinutes < 60) return '${s.inMinutes} min ago';
  if (s.inHours < 24) return '${s.inHours} h ago';
  if (s.inDays < 2) return 'yesterday';
  if (s.inDays < 7) return '${s.inDays} days ago';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]}${d.year == n.year ? '' : ' ${d.year}'}';
}

/// How long a trial lasts, in words: "a day", "12 hours", "3 days".
String trialFor(double hours) {
  if (hours == 24) return 'a day';
  if (hours % 24 == 0) return '${hours ~/ 24} days';
  return plural(hours.round(), 'hour');
}

/// How it's going, in words.
String requestStateText(ServerRequest r, [DateTime? now]) => switch (r.state) {
  _ when r.upgrading => r.state == RequestState.downloading
      ? 'Getting a better copy · ${r.progress.round()}%'
      : 'A better copy is on its way',
  RequestState.searching => 'Looking for it',
  RequestState.queued => 'Found · waiting for the sender',
  RequestState.downloading => 'Downloading · ${r.progress.round()}%',
  RequestState.done => r.arrived == null ? 'Here' : 'Arrived ${requestWhen(r.arrived, now)}',
  RequestState.notfound => 'Not found',
  RequestState.failed => 'Found, but nobody sent it',
  RequestState.setAside => 'Set aside',
  RequestState.unknown => '',
};

/// Why it was asked for, in words ("you hearted it", "in a playlist"…).
String requestWhy(ServerRequest r) {
  final why = [
    for (final x in r.reasons)
      switch (x) {
        'heart' => 'hearted',
        'playlist' => 'in a playlist',
        'trial' => 'played',
        'mix' => 'in a mix',
        'discovery' => 'a discovery',
        'lidarr' => 'wanted by Lidarr',
        _ => '',
      },
  ].where((x) => x.isNotEmpty).toList();
  return why.join(', ');
}

/// What an action is called.
const requestActionNames = {
  'retry': 'Look again',
  'setAside': 'Set aside',
  'bringBack': 'Bring back',
  'search': 'Find another file',
  'cancel': 'Stop getting it',
};

const _actionIcons = {
  'retry': Icons.refresh_rounded,
  'setAside': Icons.do_not_disturb_on_outlined,
  'bringBack': Icons.undo_rounded,
  'search': Icons.manage_search_rounded,
  'cancel': Icons.close_rounded,
};

/// Library › Playlists: the way in, on servers that say what they're getting.
class GettingTile extends ConsumerWidget {
  const GettingTile({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(requestsOfferedProvider).value != true) return const SizedBox.shrink();
    final v = ref.watch(requestsProvider).value;
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(AppLook.of(context).r(8)),
        ),
        child: Icon(Icons.downloading_rounded, color: cs.onSecondaryContainer, size: 26),
      ),
      title: Text('Getting your songs', style: Theme.of(context).textTheme.titleSmall),
      subtitle: Text(gettingSummary(v)),
      onTap: () => context.push('/getting'),
    );
  }
}

/// "2 on their way · 1 not found", or what the place is.
String gettingSummary(RequestsView? v) {
  if (v == null) return 'What your server is getting for you';
  final missing = v.pending.count(RequestState.notfound) + v.pending.count(RequestState.failed);
  final parts = [
    if (v.onTheWayCount > 0) '${v.onTheWayCount} on ${v.onTheWayCount == 1 ? 'its' : 'their'} way',
    if (missing > 0) '$missing not found',
  ];
  return parts.isEmpty ? 'Nothing on its way' : parts.join(' · ');
}

class GettingScreen extends ConsumerWidget {
  const GettingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(requestsProvider);
    final me = ref.watch(clientProvider)?.creds.username ?? '';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Getting your songs'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _refresh(context, ref),
          ),
        ],
      ),
      body: AsyncView(
        r,
        (RequestsView? v) => RefreshIndicator(
          onRefresh: () => _refresh(context, ref),
          child: v == null ? const _NotOffered() : _List(v, me: me),
        ),
        onRetry: () => ref.invalidate(requestsProvider),
      ),
    );
  }

  static Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(requestsProvider.notifier).refresh();
    } catch (e) {
      if (context.mounted) toast(context, 'Couldn\'t ask the server: ${friendlyError(e)}');
    }
  }
}

class _NotOffered extends StatelessWidget {
  const _NotOffered();
  @override
  Widget build(BuildContext context) => ListView(
    children: const [
      EmptyState(
        Icons.cloud_off_outlined,
        'Your server doesn\'t say what it\'s getting',
        hint: 'This needs Conductor 1.3 or later.',
      ),
    ],
  );
}

class _List extends StatelessWidget {
  const _List(this.v, {required this.me});
  final RequestsView v;
  final String me;

  @override
  Widget build(BuildContext context) {
    final going = v.onTheWay, missing = v.missing;
    return LayoutBuilder(
      builder: (context, box) {
        // a wide window: a readable column, not rows across the whole of it
        final side = box.maxWidth > 900 ? (box.maxWidth - 900) / 2 : 0.0;
        return ListView(
          padding: EdgeInsets.fromLTRB(side, 0, side, 96),
          children: [
            _Summary(v),
            if (v.isEmpty)
              const EmptyState(
                Icons.download_done_rounded,
                'Nothing on its way',
                hint: 'Songs you don\'t have show ⬇ in search and on artist and album pages. Play one to try it, '
                    'or heart it or add it to a playlist to keep it: your server gets it, and it shows here.',
              ),
            if (going.isNotEmpty) ...[
              SectionTitle('On their way', subtitle: _more(going.length, v.onTheWayCount)),
              for (final r in going) RequestTile(r, me: me),
            ],
            if (missing.isNotEmpty) ...[
              SectionTitle(
                'Not found',
                subtitle: 'Your server tries again now and then, for a while',
              ),
              for (final r in missing) RequestTile(r, me: me),
            ],
            if (v.arrived.isNotEmpty) ...[
              const SectionTitle('Recently arrived', subtitle: 'Tap one to play it'),
              for (final r in v.arrived) RequestTile(r, me: me),
            ],
          ],
        );
      },
    );
  }

  static String? _more(int shown, int all) => all > shown ? '$shown of $all shown' : null;
}

/// What's going on overall: how many on their way and on trial, today's trials, downloads paused.
class _Summary extends StatelessWidget {
  const _Summary(this.v);
  final RequestsView v;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final trials = v.trials;
    final lines = [
      gettingSummary(v),
      [
        if (v.pending.onTrial > 0) '${v.pending.onTrial} on trial',
        if (trials != null) '${trials.today} of ${trials.perDay} trials today',
      ].join(' · '),
    ].where((x) => x.isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            container: true,
            label: lines.join('. '),
            excludeSemantics: true,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppLook.of(context).r(14)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(lines.first, style: t.titleMedium),
                  for (final l in lines.skip(1))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(l, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    'Audition: songs you play are on trial, gone ${trialFor(trials?.hours ?? 24)} after they arrive '
                    'unless you heart them. Hearted songs and songs in your playlists are kept.',
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          if (trials != null && trials.playlistId.isNotEmpty)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Your On trial playlist'),
              subtitle: const Text('The songs on trial, to play or keep'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/playlist/${trials.playlistId}'),
            ),
          if (v.pending.downloadsPaused)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(AppLook.of(context).r(14)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.pause_circle_outline_rounded, color: cs.onErrorContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Downloads are paused on your server for now; they carry on by themselves.',
                        style: t.bodyMedium?.copyWith(color: cs.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "On trial" or "Kept", beside a song.
class _Mark extends StatelessWidget {
  const _Mark(this.trial);
  final bool trial;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: trial ? cs.tertiaryContainer : cs.secondaryContainer,
        borderRadius: BorderRadius.circular(AppLook.of(context).r(6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            trial ? Icons.timer_outlined : Icons.favorite_rounded,
            size: 13,
            color: trial ? cs.onTertiaryContainer : cs.onSecondaryContainer,
          ),
          const SizedBox(width: 4),
          Text(
            trial ? 'On trial' : 'Kept',
            style: t.labelSmall?.copyWith(color: trial ? cs.onTertiaryContainer : cs.onSecondaryContainer),
          ),
        ],
      ),
    );
  }
}

/// One request: what it is, how it's going, on trial or kept; tap an arrived song to play it; an admin's ⋮ has what
/// can be done with it.
class RequestTile extends ConsumerWidget {
  const RequestTile(this.r, {super.key, this.me = ''});
  final ServerRequest r;
  final String me; // the signed-in user (others' names are shown: an admin sees everyone's)

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final here = r.state == RequestState.done && r.songId != null;
    final others = [for (final u in r.users) if (u != me) u];
    final state = requestStateText(r);
    final why = requestWhy(r);
    final line = [
      if (r.isAlbum) 'Album',
      if (r.artist.isNotEmpty) r.artist,
      if (others.isNotEmpty) 'for ${others.join(', ')}',
    ].join(' · ');
    final actions = [
      for (final a in requestActionNames.keys)
        if (r.actions.contains(a)) a,
    ];
    final (icon, color) = switch (r.state) {
      _ when r.isAlbum => (Icons.album_rounded, cs.primary),
      RequestState.searching => (Icons.travel_explore_rounded, cs.primary),
      RequestState.queued => (Icons.hourglass_top_rounded, cs.tertiary),
      RequestState.downloading => (Icons.downloading_rounded, cs.primary),
      RequestState.done => (Icons.music_note_rounded, cs.primary),
      RequestState.setAside => (Icons.do_not_disturb_on_outlined, cs.onSurfaceVariant),
      _ => (Icons.error_outline_rounded, cs.error),
    };
    final label = [
      r.title,
      if (line.isNotEmpty) line,
      state,
      if (!r.isAlbum) r.trial && !r.kept ? 'on trial' : 'kept',
      if (why.isNotEmpty) why,
      if (here) 'double tap to play',
    ].join(', ');
    VoidCallback? tap;
    if (here) {
      tap = () => _play(context, ref);
    } else if (actions.isNotEmpty) {
      tap = () => showRequestActions(context, ref, r);
    }
    return Semantics(
      label: label,
      button: tap != null,
      excludeSemantics: true,
      customSemanticsActions: {
        for (final a in actions) CustomSemanticsAction(label: requestActionNames[a]!): () => runRequestAction(context, ref, r, a),
        if (here) const CustomSemanticsAction(label: 'More'): () => _menu(context, ref),
      },
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        leading: SizedBox(width: 40, child: Icon(icon, color: color)),
        title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (line.isNotEmpty) Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              [state, if (why.isNotEmpty) why].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall?.copyWith(color: r.missing ? cs.error : cs.onSurfaceVariant),
            ),
            if (r.state == RequestState.downloading)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: LinearProgressIndicator(
                  value: r.progress / 100,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(AppLook.of(context).r(1)),
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!r.isAlbum) _Mark(r.trial && !r.kept),
            if (actions.isNotEmpty)
              IconButton(
                tooltip: 'What to do with it',
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: () => showRequestActions(context, ref, r),
              )
            else if (here)
              IconButton(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: () => _menu(context, ref),
              )
            else
              const SizedBox(width: 12),
          ],
        ),
        onTap: tap,
        onLongPress: here ? () => _menu(context, ref) : null,
      ),
    );
  }

  Future<Song?> _song(BuildContext context, WidgetRef ref) async {
    final c = ref.read(clientProvider);
    if (c == null || r.songId == null) return null;
    try {
      return await c.song(r.songId!);
    } catch (e) {
      if (context.mounted) toast(context, 'Couldn\'t find it on your server: ${friendlyError(e)}');
      return null;
    }
  }

  Future<void> _play(BuildContext context, WidgetRef ref) async {
    final s = await _song(context, ref);
    if (s != null) await audioHandler.playSongs([s], source: 'Getting your songs');
  }

  Future<void> _menu(BuildContext context, WidgetRef ref) async {
    final s = await _song(context, ref);
    if (s != null && context.mounted) await showSongMenu(context, ref, s);
  }
}

/// An admin's actions on a request, as a sheet.
Future<void> showRequestActions(BuildContext context, WidgetRef ref, ServerRequest r) => showAppSheet(
  context: context,
  menu: true,
  showDragHandle: true,
  useRootNavigator: true,
  isScrollControlled: true,
  builder: (ctx) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      children: [
        ListTile(
          title: Text(r.title, style: Theme.of(ctx).textTheme.titleMedium),
          subtitle: Text([
            if (r.artist.isNotEmpty) r.artist,
            requestStateText(r),
            if (r.from.isNotEmpty) 'from ${r.from}',
            if (r.note.isNotEmpty) r.note,
          ].join(' · ')),
        ),
        for (final a in requestActionNames.keys)
          if (r.actions.contains(a))
            ListTile(
              leading: Icon(_actionIcons[a]),
              title: Text(requestActionNames[a]!),
              onTap: () {
                Navigator.pop(ctx);
                runRequestAction(context, ref, r, a);
              },
            ),
        const SizedBox(height: 8),
      ],
    ),
  ),
);

/// Does [action] to [r] (an admin), says how it went, and asks for the list again.
Future<void> runRequestAction(BuildContext context, WidgetRef ref, ServerRequest r, String action) async {
  final c = ref.read(clientProvider);
  if (c == null) return;
  if (action == 'search') {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FindFileScreen(r)));
    return;
  }
  if (action == 'cancel' &&
      !await confirm(
        context,
        'Stop getting it?',
        'Your server stops looking for "${r.title}" and forgets it was asked for.',
        ok: 'Stop',
      )) {
    return;
  }
  try {
    switch (action) {
      case 'retry':
        await c.retryRequest(r.id);
        if (context.mounted) toast(context, 'Looking for "${r.title}" again');
      case 'setAside':
        await c.setRequestAside(r.id);
        if (context.mounted) toast(context, '"${r.title}" is set aside');
      case 'bringBack':
        await c.setRequestAside(r.id, aside: false);
        if (context.mounted) toast(context, '"${r.title}" is back');
      case 'cancel':
        await c.cancelRequest(r.id);
        if (context.mounted) toast(context, 'Stopped getting "${r.title}"');
    }
  } catch (e) {
    if (context.mounted) toast(context, friendlyError(e));
  }
  await ref.read(requestsProvider.notifier).acted();
}

/// An admin's own Soulseek search for a request, and a file picked from what it found.
class FindFileScreen extends ConsumerStatefulWidget {
  const FindFileScreen(this.request, {super.key});
  final ServerRequest request;
  @override
  ConsumerState<FindFileScreen> createState() => _FindFileScreenState();
}

class _FindFileScreenState extends ConsumerState<FindFileScreen> {
  late final _query = TextEditingController(text: widget.request.query);
  RequestFiles? _found;
  String? _error;
  bool _searching = false, _picking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final c = ref.read(clientProvider);
    final q = _query.text.trim();
    if (c == null || _searching) return;
    if (q.length < 3) {
      setState(() => _error = 'Type at least 3 letters');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final f = await c.searchRequestFiles(widget.request.id, query: q);
      if (mounted) setState(() => _found = f);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _pick(RequestFile f) async {
    final c = ref.read(clientProvider);
    if (c == null || _picking) return;
    if (!await confirm(context, 'Get this file?', '${f.name}\nfrom ${f.user}', ok: 'Get it')) return;
    setState(() => _picking = true);
    try {
      await c.pickRequestFile(widget.request.id, f);
      await ref.read(requestsProvider.notifier).acted();
      if (!mounted) return;
      toast(context, 'Getting "${widget.request.title}" from ${f.user}');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) toast(context, friendlyError(e));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final found = _found;
    return Scaffold(
      appBar: AppBar(title: Text('Find a file for "${widget.request.title}"')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    decoration: const InputDecoration(labelText: 'Search Soulseek for'),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                  ),
                ),
                IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.search_rounded),
                  onPressed: _searching ? null : _search,
                ),
              ],
            ),
          ),
          if (_searching || _picking) const LinearProgressIndicator(),
          Expanded(
            child: _searching
                ? const EmptyState(
                    Icons.manage_search_rounded,
                    'Searching Soulseek…',
                    hint: 'This takes up to 40 seconds.',
                  )
                : _error != null
                ? EmptyState(
                    Icons.error_outline_rounded,
                    'Couldn\'t search',
                    hint: _error,
                    action: TextButton(onPressed: _search, child: const Text('Try again')),
                  )
                : found == null
                ? const SizedBox.shrink()
                : found.files.isEmpty
                ? const EmptyState(Icons.search_off_rounded, 'Nothing found', hint: 'Try other words.')
                : ListView(
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Text(
                          found.total > found.files.length
                              ? 'The likeliest ${found.files.length} of ${found.total} files'
                              : plural(found.files.length, 'file'),
                          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                      for (final f in found.files) _FileTile(f, onTap: _picking ? null : () => _pick(f)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile(this.f, {this.onTap});
  final RequestFile f;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final quality = [
      f.ext.toUpperCase(),
      if (f.bitrate > 0) '${f.bitrate} kbps',
      if (f.size > 0) '${(f.size / 1048576).toStringAsFixed(1)} MB',
      if (f.length > 0) formatDuration(f.length.round()),
    ].where((x) => x.isNotEmpty).join(' · ');
    final fits = [
      if (f.match) 'what the automatic search would take',
      if (f.titleOk && f.artistOk) 'title and artist match' else if (f.titleOk) 'title matches',
      if (f.sameAlbum) 'same album',
    ];
    final peer = [f.user, f.free ? 'free to send now' : 'queue ${f.queue}'].join(' · ');
    return Semantics(
      label: [f.name, quality, peer, ...fits].join(', '),
      button: true,
      excludeSemantics: true,
      child: ListTile(
        leading: Icon(
          f.match ? Icons.check_circle_rounded : Icons.audio_file_outlined,
          color: f.match ? cs.primary : cs.onSurfaceVariant,
        ),
        title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [if (f.folder.isNotEmpty) f.folder, quality, peer, if (fits.isNotEmpty) fits.join(', ')].join('\n'),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        onTap: onTap,
      ),
    );
  }
}
