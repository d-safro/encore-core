import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/settings.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../playback/handler.dart';
import '../actions.dart';
import '../widgets.dart';

/// One entry in "Recent searches": a song, album or artist you opened from search, or a search you typed.
class RecentItem {
  RecentItem(this.kind, this.id, this.title, {this.subtitle = '', this.cover = '', this.song});
  final String kind; // song, album, artist, query
  final String id, title, subtitle, cover;
  final Song? song;

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'cover': cover,
    if (song != null) 'song': song!.toJson(),
  };

  static RecentItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = '${j['kind'] ?? ''}', id = '${j['id'] ?? ''}';
    if (kind.isEmpty || id.isEmpty) return null;
    final sj = j['song'];
    return RecentItem(
      kind,
      id,
      '${j['title'] ?? ''}',
      subtitle: '${j['subtitle'] ?? ''}',
      cover: '${j['cover'] ?? ''}',
      song: sj is Map ? Song.fromJson(sj.cast<String, dynamic>()) : null,
    );
  }
}

/// Recent searches, newest first (at most 30), kept on the phone. Older apps saved only typed text.
List<RecentItem> recentSearches() {
  final out = <RecentItem>[];
  try {
    for (final e in jsonDecode(prefs.getString('recentSearch') ?? '[]') as List) {
      final r = RecentItem.fromJson(e);
      if (r != null) out.add(r);
    }
  } catch (_) {}
  if (out.isEmpty) {
    for (final q in prefs.getStringList('searchHistory') ?? const <String>[]) {
      out.add(RecentItem('query', q, q));
    }
  }
  return out;
}

void _saveRecents(List<RecentItem> l) =>
    prefs.setString('recentSearch', jsonEncode(l.take(30).map((e) => e.toJson()).toList()));

void addRecent(RecentItem r) =>
    _saveRecents([r, ...recentSearches().where((x) => !(x.kind == r.kind && x.id == r.id))]);

void removeRecent(RecentItem r) =>
    _saveRecents(recentSearches().where((x) => !(x.kind == r.kind && x.id == r.id)).toList());

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  void _safeSetState(VoidCallback f) {
    if (mounted) setState(f);
  }

  final _ctl = TextEditingController();
  Timer? _debounce;
  SearchResult? _result;
  String _query = '';
  bool _loading = false;
  String? _error;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _changed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _run(q));
  }

  Future<void> _run(String q) async {
    q = q.trim();
    _safeSetState(() {
      _query = q;
      _error = null;
    });
    if (q.length < 2) {
      _safeSetState(() => _result = null);
      return;
    }
    final seq = ++_seq;
    _safeSetState(() => _loading = true);
    try {
      final r = await ref.read(repoProvider).search(q);
      if (seq != _seq) return;
      _safeSetState(() => _result = r);
    } catch (e) {
      if (seq == _seq) _safeSetState(() => _error = '$e');
    } finally {
      if (seq == _seq && mounted) _safeSetState(() => _loading = false);
    }
  }

  void _remember(String q) {
    if (q.length < 2) return;
    addRecent(RecentItem('query', q, q));
  }

  void _rememberSong(Song x) =>
      addRecent(RecentItem('song', x.id, x.title, subtitle: 'Song · ${x.artist}', cover: x.coverArt, song: x));

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
                },
              ),
          ],
          elevation: const WidgetStatePropertyAll(0),
          onChanged: _changed,
          onSubmitted: (q) {
            _remember(q.trim());
            _run(q);
          },
        ),
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body(r, showLookup)),
        ],
      ),
    );
  }

  Widget _body(SearchResult? r, bool showLookup) {
    if (_error != null) return Center(child: Text(_error!));
    if (r == null) {
      final recents = recentSearches();
      final cs = Theme.of(context).colorScheme;
      return ListView(
        children: [
          if (recents.isNotEmpty)
            SectionTitle(
              'Recent searches',
              trailing: TextButton(
                onPressed: () => _safeSetState(() {
                  prefs.remove('recentSearch');
                  prefs.remove('searchHistory');
                }),
                child: const Text('Clear all'),
              ),
            ),
          for (final h in recents)
            ListTile(
              leading: switch (h.kind) {
                'query' => const SizedBox(width: 48, height: 48, child: Icon(Icons.history)),
                'artist' => Cover(h.cover, size: 48, circle: true, icon: Icons.person),
                _ => Cover(h.cover, size: 48, radius: 6, icon: Icons.music_note_outlined),
              },
              title: Text(h.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: h.subtitle.isEmpty
                  ? null
                  : Text(
                      h.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 20),
                tooltip: 'Remove',
                onPressed: () => _safeSetState(() => removeRecent(h)),
              ),
              onTap: () {
                addRecent(h); // back to the top
                switch (h.kind) {
                  case 'query':
                    _ctl.text = h.title;
                    _run(h.title);
                  case 'artist':
                    context.push('/artist/${h.id}');
                  case 'album':
                    context.push('/album/${h.id}');
                  case 'song':
                    final x = h.song;
                    if (x == null) return;
                    if (x.isLookup) {
                      showSongMenu(context, ref, x);
                    } else {
                      audioHandler.playSongs([x]);
                    }
                }
                _safeSetState(() {});
              },
            ),
        ],
      );
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
      child: ListView(
        children: [
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
                        addRecent(RecentItem('artist', a.id, a.name, subtitle: 'Artist', cover: a.coverArt));
                        context.push('/artist/${a.id}');
                      },
                      child: Column(
                        children: [
                          Stack(
                            children: [
                              Cover(a.coverArt, size: 96, circle: true, icon: Icons.person),
                              if (a.isLookup) Positioned(right: 0, top: 0, child: LookupBadge(a.lookup)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(a.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          if (songs.isNotEmpty) ...[
            const SectionTitle('Songs'),
            for (var i = 0; i < songs.length && i < 30; i++)
              GestureDetector(
                onTapDown: (_) {
                  remember();
                  _rememberSong(songs[i]);
                },
                child: SongTile(songs[i], list: songs, index: i),
              ),
          ],
          if (albums.isNotEmpty)
            Shelf(
              title: 'Albums',
              children: [
                for (final a in albums)
                  GestureDetector(
                    onTapDown: (_) {
                      remember();
                      addRecent(RecentItem('album', a.id, a.name, subtitle: 'Album · ${a.artist}', cover: a.coverArt));
                    },
                    child: AlbumCard(a),
                  ),
              ],
            ),
          if (lookupSongs.isNotEmpty || lookupAlbums.isNotEmpty) ...[
            const Divider(height: 32),
            const SectionTitle('Not in your library'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Tap to download through your server, or play a preview.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final x in lookupSongs.take(30))
              GestureDetector(
                onTapDown: (_) {
                  remember();
                  _rememberSong(x);
                },
                child: SongTile(x),
              ),
            if (lookupAlbums.isNotEmpty)
              Shelf(title: 'Albums to get', children: [for (final a in lookupAlbums) AlbumCard(a)]),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
