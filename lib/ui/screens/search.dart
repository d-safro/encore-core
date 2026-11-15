import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/settings.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../widgets.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctl = TextEditingController();
  Timer? _debounce;
  SearchResult? _result;
  String _query = '';
  bool _loading = false;
  String? _error;
  int _seq = 0;

  List<String> get _history => prefs.getStringList('searchHistory') ?? const [];

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _run(q));
  }

  Future<void> _run(String q) async {
    q = q.trim();
    setState(() {
      _query = q;
      _error = null;
    });
    if (q.length < 2) {
      setState(() => _result = null);
      return;
    }
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      final r = await ref.read(repoProvider).search(q);
      if (seq != _seq) return;
      setState(() => _result = r);
    } catch (e) {
      if (seq == _seq) setState(() => _error = '$e');
    } finally {
      if (seq == _seq && mounted) setState(() => _loading = false);
    }
  }

  void _remember(String q) {
    if (q.length < 2) return;
    final h = [q, ..._history.where((x) => x != q)].take(15).toList();
    prefs.setStringList('searchHistory', h);
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final showLookup = ref.watch(settingsProvider.select((s) => s.showLookup));
    final offline = ref.watch(offlineProvider);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: SearchBar(
          controller: _ctl,
          hintText: offline ? 'Search downloaded music' : 'Songs, albums, artists',
          leading: const Icon(Icons.search),
          trailing: [
            if (_ctl.text.isNotEmpty)
              IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _ctl.clear();
                    _run('');
                  }),
          ],
          elevation: const WidgetStatePropertyAll(0),
          onChanged: _changed,
          onSubmitted: (q) {
            _remember(q.trim());
            _run(q);
          },
        ),
      ),
      body: Column(children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _body(r, showLookup)),
      ]),
    );
  }

  Widget _body(SearchResult? r, bool showLookup) {
    if (_error != null) return Center(child: Text(_error!));
    if (r == null) {
      return ListView(children: [
        if (_history.isNotEmpty)
          SectionTitle('Recent searches',
              trailing: TextButton(
                  onPressed: () => setState(() => prefs.remove('searchHistory')), child: const Text('Clear'))),
        for (final h in _history)
          ListTile(
            leading: const Icon(Icons.history),
            title: Text(h),
            onTap: () {
              _ctl.text = h;
              _run(h);
            },
          ),
      ]);
    }
    if (r.isEmpty && !_loading) return Center(child: Text('Nothing found for "$_query"'));
    final songs = r.songs.where((s) => !s.isLookup).toList();
    final lookupSongs = showLookup ? r.songs.where((s) => s.isLookup).toList() : const <Song>[];
    final albums = r.albums.where((a) => !a.isLookup).toList();
    final lookupAlbums = showLookup ? r.albums.where((a) => a.isLookup).toList() : const <Album>[];
    final artists = r.artists.where((a) => showLookup || !a.isLookup).toList();
    void remember() => _remember(_query);
    return NotificationListener<ScrollStartNotification>(
      onNotification: (_) {
        FocusScope.of(context).unfocus();
        return false;
      },
      child: ListView(children: [
        if (artists.isNotEmpty)
          Shelf(
            title: 'Artists',
            height: 150,
            children: [
              for (final a in artists)
                SizedBox(
                  width: 110,
                  child: InkWell(
                    onTap: () {
                      remember();
                      context.push('/artist/${a.id}');
                    },
                    child: Column(children: [
                      Stack(children: [
                        Cover(a.coverArt, size: 96, circle: true, icon: Icons.person),
                        if (a.isLookup) Positioned(right: 0, top: 0, child: LookupBadge(a.lookup)),
                      ]),
                      const SizedBox(height: 6),
                      Text(a.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                ),
            ],
          ),
        if (songs.isNotEmpty) ...[
          const SectionTitle('Songs'),
          for (var i = 0; i < songs.length && i < 30; i++)
            GestureDetector(onTapDown: (_) => remember(), child: SongTile(songs[i], list: songs, index: i)),
        ],
        if (albums.isNotEmpty) Shelf(title: 'Albums', children: [for (final a in albums) AlbumCard(a)]),
        if (lookupSongs.isNotEmpty || lookupAlbums.isNotEmpty) ...[
          const Divider(height: 32),
          const SectionTitle('Not in your library'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Tap to download through your server, or play a preview.',
                style: Theme.of(context).textTheme.bodySmall),
          ),
          for (final s in lookupSongs.take(30)) SongTile(s),
          if (lookupAlbums.isNotEmpty) Shelf(title: 'Albums to get', children: [for (final a in lookupAlbums) AlbumCard(a)]),
        ],
        const SizedBox(height: 24),
      ]),
    );
  }
}
