import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../data/audiobooks.dart';
import '../../data/book_downloads.dart';
import '../../data/library.dart' show offlineProvider;
import '../../playback/handler.dart';
import '../actions.dart' show toast;
import '../widgets.dart';

Future<void> _listen(BuildContext context, WidgetRef ref, Book b, {double? at}) async {
  final a = ref.read(absAccountProvider);
  final kept = ref.read(bookDownloadsProvider).kept[b.id];
  if (a == null && kept == null) return;
  try {
    await listen(
      ref.read(offlineProvider) ? null : a,
      b,
      at: at,
      local: kept?.tracks,
      play: (songs, index, pos) async {
        await audioHandler.playSongs(songs, index: index);
        if (pos > Duration.zero) await audioHandler.seek(pos);
      },
    );
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t play it: $e');
  }
}

/// The Audiobooks tab: what you're listening to, then every book.
class AudiobooksScreen extends ConsumerStatefulWidget {
  const AudiobooksScreen({super.key});
  @override
  ConsumerState<AudiobooksScreen> createState() => _AudiobooksScreenState();
}

class _AudiobooksScreenState extends ConsumerState<AudiobooksScreen> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final a = ref.watch(absAccountProvider);
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Audiobooks')),
      body: a == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.headphones_rounded, size: 48),
                    const SizedBox(height: 12),
                    Text('Your audiobooks, from Audiobookshelf', style: t.titleMedium, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: () => showAbsSignIn(context, ref), child: const Text('Sign in')),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(booksProvider),
              child: AsyncView(
                ref.watch(booksProvider),
                (List<Book> all) {
                  final f = _filter.toLowerCase();
                  final shown = f.isEmpty
                      ? all
                      : all
                            .where((b) => b.title.toLowerCase().contains(f) || b.author.toLowerCase().contains(f))
                            .toList();
                  final going = all.where((b) => b.started).toList()..sort((x, y) => y.progress.compareTo(x.progress));
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      if (ref.watch(bookDownloadsProvider).kept.isNotEmpty && f.isEmpty)
                        Shelf(
                          title: 'On this device',
                          children: [for (final k in ref.watch(bookDownloadsProvider).kept.values) BookCard(k.book)],
                        ),
                      if (going.isNotEmpty && f.isEmpty)
                        Shelf(title: 'Continue listening', children: [for (final b in going) BookCard(b)]),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: TextField(
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search_rounded),
                            hintText: 'Title or author',
                          ),
                          onChanged: (v) => setState(() => _filter = v.trim()),
                        ),
                      ),
                      if (shown.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(
                            child: Text('No audiobooks here yet. Add some to your Audiobookshelf library.'),
                          ),
                        ),
                      for (final b in shown)
                        ListTile(
                          leading: Cover(b.cover, size: 52, radius: 8, icon: Icons.headphones_rounded),
                          title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            [
                              b.author,
                              bookLength(b.duration),
                              if (b.finished) 'finished' else if (b.started) '${(b.progress * 100).round()}%',
                            ].where((x) => x.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => context.push('/audiobook/${b.id}'),
                        ),
                    ],
                  );
                },
                onRetry: () => ref.invalidate(booksProvider),
                error: (e) => _OfflineBooks(e),
              ),
            ),
    );
  }
}

/// No server (offline, or Audiobookshelf away): the books on this device.
class _OfflineBooks extends ConsumerWidget {
  const _OfflineBooks(this.why);
  final Object why;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kept = ref.watch(bookDownloadsProvider).kept.values.toList();
    return ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.cloud_off_rounded),
          title: Text(kept.isEmpty ? '$why' : 'Audiobookshelf isn\'t answering: your downloaded books'),
        ),
        for (final k in kept)
          ListTile(
            leading: Cover(k.book.cover, size: 52, radius: 8, icon: Icons.headphones_rounded),
            title: Text(k.book.title),
            subtitle: Text(k.book.author),
            onTap: () => _listen(context, ref, k.book),
          ),
      ],
    );
  }
}

class BookCard extends ConsumerWidget {
  const BookCard(this.b, {super.key});
  final Book b;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: AppLook.of(context).cardWidth,
      child: Tappable(
        onTap: () => context.push('/audiobook/${b.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Cover(b.cover, size: double.infinity, radius: 14, icon: Icons.headphones_rounded),
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: b.progress, minHeight: 3, borderRadius: BorderRadius.circular(2)),
            const SizedBox(height: 6),
            Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleSmall),
            Text(
              '${bookLength(b.duration * (1 - b.progress))} left',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// A book: play or carry on, its chapters.
class AudiobookScreen extends ConsumerWidget {
  const AudiobookScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(),
      body: AsyncView(
        ref.watch(bookProvider(id)),
        error: (e) {
          // offline: the copy kept on this device, if any
          final k = ref.watch(bookDownloadsProvider).kept[id];
          return k == null ? Center(child: Text('$e')) : _BookPage(k.book);
        },
        (Book b) => _BookPage(b),
        onRetry: () => ref.invalidate(bookProvider(id)),
      ),
    );
  }
}

class _BookPage extends ConsumerWidget {
  const _BookPage(this.b);
  final Book b;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final dl = ref.watch(bookDownloadsProvider);
    final kept = dl.kept.containsKey(b.id), going = dl.progress[b.id];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Center(child: Cover(b.cover, size: 220, radius: 16, icon: Icons.headphones_rounded)),
        const SizedBox(height: 16),
        Text(b.title, style: t.headlineSmall, textAlign: TextAlign.center),
        Text(
          [
            if (b.author.isNotEmpty) b.author,
            if (b.narrator.isNotEmpty) 'read by ${b.narrator}',
            bookLength(b.duration),
          ].join(' · '),
          style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        if (b.started) ...[
          LinearProgressIndicator(value: b.progress, borderRadius: BorderRadius.circular(2)),
          const SizedBox(height: 4),
          Text('${bookLength(b.duration - b.position)} left', style: t.bodySmall, textAlign: TextAlign.center),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(b.started ? 'Carry on' : (b.finished ? 'Listen again' : 'Listen')),
          onPressed: () => _listen(context, ref, b, at: b.finished ? 0 : null),
        ),
        const SizedBox(height: 8),
        // keep it on this device for listening offline
        if (going != null)
          OutlinedButton.icon(
            icon: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, value: going > 0 ? going : null),
            ),
            label: Text('Downloading ${(going * 100).round()}% · Stop'),
            onPressed: () => ref.read(bookDownloadsProvider.notifier).cancel(b.id),
          )
        else if (kept)
          OutlinedButton.icon(
            icon: const Icon(Icons.download_done_rounded),
            label: const Text('On this device · Remove'),
            onPressed: () => ref.read(bookDownloadsProvider.notifier).remove(b.id),
          )
        else
          OutlinedButton.icon(
            icon: const Icon(Icons.download_rounded),
            label: Text(dl.failed[b.id] != null ? 'Download again (it stopped)' : 'Download for offline'),
            onPressed: () {
              final a = ref.read(absAccountProvider);
              if (a != null) ref.read(bookDownloadsProvider.notifier).download(a, b);
            },
          ),
        if (b.description.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            b.description.replaceAll(RegExp(r'<[^>]+>'), ''),
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: t.bodyMedium,
          ),
        ],
        if (b.chapters.isNotEmpty) ...[
          const SectionTitle('Chapters'),
          for (final c in b.chapters)
            ListTile(
              dense: true,
              leading: Icon(
                b.position >= c.end
                    ? Icons.check_rounded
                    : (b.position >= c.start ? Icons.graphic_eq_rounded : Icons.circle_outlined),
                size: 18,
                color: b.position >= c.start ? cs.primary : cs.onSurfaceVariant,
              ),
              title: Text(c.title),
              trailing: Text(bookLength(c.end - c.start), style: t.bodySmall),
              onTap: () => _listen(context, ref, b, at: c.start),
            ),
        ],
      ],
    );
  }
}

/// Settings › Audiobooks: sign in to Audiobookshelf.
Future<void> showAbsSignIn(BuildContext context, WidgetRef ref) async {
  final addr = TextEditingController(), user = TextEditingController(), pass = TextEditingController();
  String? problem;
  var busy = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: const Text('Audiobookshelf'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: addr,
              decoration: const InputDecoration(labelText: 'Address', hintText: 'https://audiobooks.your-server'),
            ),
            TextField(
              controller: user,
              decoration: const InputDecoration(labelText: 'Username'),
              autocorrect: false,
            ),
            TextField(
              controller: pass,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
            if (problem != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(problem!)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    set(() => busy = true);
                    try {
                      final a = await absSignIn(addr.text, user.text.trim(), pass.text);
                      await ref.read(absAccountProvider.notifier).signIn(a);
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      set(() {
                        busy = false;
                        problem = '$e';
                      });
                    }
                  },
            child: const Text('Sign in'),
          ),
        ],
      ),
    ),
  );
}
