import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/ai.dart';
import '../../data/models.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../widgets.dart';

final _examplesProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  final ai = ref.watch(aiProvider);
  return ai == null ? const <String>[] : ai.examplePrompts();
});

/// AI recommendations from AudioMuse-AI on your server: it listens to every song and knows how they sound.
class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({super.key});

  void _open(BuildContext context, String title, String subtitle, Future<List<Song>> Function(Ai ai) load) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AiResultsScreen(title: title, subtitle: subtitle, load: load)));
  }

  Future<void> _play(BuildContext context, WidgetRef ref, Future<List<Song>> Function(Ai ai) load, {bool shuffle = false}) async {
    final ai = ref.read(aiProvider);
    if (ai == null) return;
    toast(context, 'Making your mix…');
    try {
      final songs = await load(ai);
      if (songs.isEmpty) {
        if (context.mounted) toast(context, 'Nothing came back. AudioMuse may still be analysing your music.');
        return;
      }
      await audioHandler.playSongs(songs, shuffle: shuffle);
    } catch (e) {
      if (context.mounted) toast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ai = ref.watch(aiProvider);
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    if (ai == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Discover')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text('AI recommendations need your server, so they aren\'t available offline.', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    return Scaffold(
      body: CustomScrollView(slivers: [
        const SliverAppBar.large(title: Text('Discover')),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              color: cs.primaryContainer,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _open(context, 'Made for you', 'Songs that sound like what you play most', (ai) => ai.forYou()),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.auto_awesome, color: cs.onPrimaryContainer),
                      const SizedBox(width: 8),
                      Text('Made for you', style: t.titleLarge?.copyWith(color: cs.onPrimaryContainer)),
                    ]),
                    const SizedBox(height: 6),
                    Text('A mix from your sonic fingerprint: songs that sound like what you listen to most.',
                        style: t.bodyMedium?.copyWith(color: cs.onPrimaryContainer)),
                    const SizedBox(height: 16),
                    Row(children: [
                      FilledButton.icon(
                        onPressed: () => _play(context, ref, (ai) => ai.forYou()),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => _open(context, 'Made for you', 'Songs that sound like what you play most', (ai) => ai.forYou()),
                        child: Text('See songs', style: TextStyle(color: cs.onPrimaryContainer)),
                      ),
                    ]),
                  ]),
                ),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SectionTitle('Moods')),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220, childAspectRatio: 2.6, mainAxisSpacing: 8, crossAxisSpacing: 8),
            delegate: SliverChildListDelegate([
              for (final e in aiMoods.entries)
                _MoodTile(
                  mood: e.key,
                  label: e.value,
                  onTap: () => _play(context, ref, (ai) => ai.mood(e.key), shuffle: true),
                  onLongPress: () => _open(context, e.value, 'Songs that feel ${e.value.toLowerCase()}', (ai) => ai.mood(e.key)),
                ),
            ]),
          ),
        ),
        SliverToBoxAdapter(
          child: _PromptCard(
            icon: Icons.graphic_eq,
            title: 'Describe a sound',
            hint: 'calm piano at night, upbeat 80s synth…',
            examples: ref.watch(_examplesProvider).value ?? const [],
            onSubmit: (q) => _open(context, q, 'Songs that sound like that', (ai) => ai.describe(q)),
          ),
        ),
        SliverToBoxAdapter(
          child: _PromptCard(
            icon: Icons.notes,
            title: 'Songs about…',
            hint: 'leaving home, summer love, the sea…',
            examples: const ['heartbreak in the rain', 'road trip', 'missing someone', 'growing up', 'the night city'],
            onSubmit: (q) => _open(context, 'About "$q"', 'Matched by what the lyrics mean', (ai) => ai.lyricsAbout(q)),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.science_outlined),
                  title: const Text('Song alchemy'),
                  subtitle: const Text('Blend songs into a new mix, or steer away from a sound'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AlchemyScreen())),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.timeline),
                  title: const Text('From one song to another'),
                  subtitle: const Text('A gradual path of songs between two sounds'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final from = await pickSong(context, ref, 'Start with…');
                    if (from != null && context.mounted) await bridgeMix(context, ref, from);
                  },
                ),
              ]),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ]),
    );
  }
}

class _MoodTile extends StatelessWidget {
  const _MoodTile({required this.mood, required this.label, required this.onTap, required this.onLongPress});
  final String mood, label;
  final VoidCallback onTap, onLongPress;

  static const _icons = {
    'happy': Icons.sentiment_very_satisfied,
    'relaxed': Icons.spa_outlined,
    'sad': Icons.water_drop_outlined,
    'danceable': Icons.nightlife,
    'party': Icons.celebration_outlined,
    'aggressive': Icons.bolt,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final colors = [cs.primaryContainer, cs.secondaryContainer, cs.tertiaryContainer];
    final on = [cs.onPrimaryContainer, cs.onSecondaryContainer, cs.onTertiaryContainer];
    final i = aiMoods.keys.toList().indexOf(mood) % 3;
    return Material(
      color: colors[i],
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            Icon(_icons[mood], color: on[i]),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: on[i]))),
            Icon(Icons.play_arrow_rounded, color: on[i]),
          ]),
        ),
      ),
    );
  }
}

class _PromptCard extends StatefulWidget {
  const _PromptCard({required this.icon, required this.title, required this.hint, required this.examples, required this.onSubmit});
  final IconData icon;
  final String title, hint;
  final List<String> examples;
  final void Function(String) onSubmit;
  @override
  State<_PromptCard> createState() => _PromptCardState();
}

class _PromptCardState extends State<_PromptCard> {
  final _ctl = TextEditingController();

  void _go(String q) {
    q = q.trim();
    if (q.length < 3) return;
    FocusScope.of(context).unfocus();
    widget.onSubmit(q);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(widget.icon),
              const SizedBox(width: 8),
              Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _ctl,
              textInputAction: TextInputAction.search,
              onSubmitted: _go,
              decoration: InputDecoration(
                hintText: widget.hint,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: () => _go(_ctl.text)),
              ),
            ),
            if (widget.examples.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 0, children: [
                for (final e in widget.examples.take(6))
                  ActionChip(label: Text(e), visualDensity: VisualDensity.compact, onPressed: () => _go(e)),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}

/// A list of AI-picked songs with play / shuffle / save as playlist.
class AiResultsScreen extends ConsumerStatefulWidget {
  const AiResultsScreen({super.key, required this.title, required this.subtitle, required this.load});
  final String title, subtitle;
  final Future<List<Song>> Function(Ai ai) load;
  @override
  ConsumerState<AiResultsScreen> createState() => _AiResultsScreenState();
}

class _AiResultsScreenState extends ConsumerState<AiResultsScreen> {
  late Future<List<Song>> _future = _run();

  Future<List<Song>> _run() {
    final ai = ref.read(aiProvider);
    if (ai == null) return Future.error('AI recommendations need your server');
    return widget.load(ai);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(tooltip: 'Try again', icon: const Icon(Icons.refresh), onPressed: () => setState(() => _future = _run())),
        ],
      ),
      body: FutureBuilder<List<Song>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}', textAlign: TextAlign.center)));
          }
          if (!snap.hasData) {
            return const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Listening through your library…'),
            ]));
          }
          final songs = snap.data!;
          if (songs.isEmpty) {
            return const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Nothing matched. Try other words, or wait until AudioMuse has analysed more of your music.',
                        textAlign: TextAlign.center)));
          }
          return ListView(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text('${widget.subtitle} · ${songs.length} songs', style: Theme.of(context).textTheme.bodySmall),
            ),
            PlayButtons(
              onPlay: () => audioHandler.playSongs(songs),
              onShuffle: () => audioHandler.playSongs(songs, shuffle: true),
              extra: [
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  tooltip: 'Save as playlist',
                  icon: const Icon(Icons.playlist_add),
                  onPressed: () => addToPlaylist(context, ref, songs),
                ),
              ],
            ),
            for (var i = 0; i < songs.length; i++) SongTile(songs[i], list: songs, index: i),
            const SizedBox(height: 24),
          ]);
        },
      ),
    );
  }
}

/// Song alchemy: songs to blend (+) and songs to steer away from (−).
class AlchemyScreen extends ConsumerStatefulWidget {
  const AlchemyScreen({super.key});
  @override
  ConsumerState<AlchemyScreen> createState() => _AlchemyScreenState();
}

class _AlchemyScreenState extends ConsumerState<AlchemyScreen> {
  final _add = <Song>[], _sub = <Song>[];

  Future<void> _pick(List<Song> into, String title) async {
    final s = await pickSong(context, ref, title);
    if (s != null && !_add.any((x) => x.id == s.id) && !_sub.any((x) => x.id == s.id)) setState(() => into.add(s));
  }

  Widget _list(String title, String help, List<Song> songs, IconData icon, String pickTitle) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(leading: Icon(icon), title: Text(title), subtitle: Text(help)),
            for (final s in songs)
              ListTile(
                dense: true,
                leading: Cover(s.coverArt, size: 40, radius: 6, icon: Icons.music_note),
                title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(s.artist, maxLines: 1),
                trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => songs.remove(s))),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TextButton.icon(onPressed: () => _pick(songs, pickTitle), icon: const Icon(Icons.add), label: const Text('Add a song')),
            ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Song alchemy')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _list('Blend', 'The mix sounds like all of these together', _add, Icons.add_circle_outline, 'Blend in…'),
        const SizedBox(height: 8),
        _list('Steer away from', 'Optional: songs that sound like these are left out', _sub, Icons.remove_circle_outline, 'Steer away from…'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _add.isEmpty
              ? null
              : () {
                  final add = [..._add], sub = [..._sub];
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AiResultsScreen(
                      title: 'Alchemy mix',
                      subtitle: 'Blend of ${add.map((s) => s.title).join(', ')}${sub.isEmpty ? '' : ' without the sound of ${sub.map((s) => s.title).join(', ')}'}',
                      load: (ai) => ai.alchemy(add, sub),
                    ),
                  ));
                },
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Make the mix'),
        ),
        if (_sub.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('Tip: if a song you steer away from sounds very close to one you blend in, little or nothing is left.',
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ]),
    );
  }
}
