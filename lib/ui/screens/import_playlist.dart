import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/account.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../data/playlist_import.dart';
import '../actions.dart' show toast;
import '../state.dart' show playlistsProvider;
import '../widgets.dart';

/// Import a playlist from another app (playlist_import.dart): pick the export file, choose the playlists in
/// it, see what matched, then make them on your server. Songs you don't have can be got (⬇).
class ImportPlaylistScreen extends ConsumerStatefulWidget {
  const ImportPlaylistScreen({super.key});
  @override
  ConsumerState<ImportPlaylistScreen> createState() => _ImportPlaylistScreenState();
}

class _Matched {
  _Matched(this.list);
  final ImportedPlaylist list;
  final songs = <(ImportEntry, Song?)>[];
  bool chosen = true;
  late final name = TextEditingController(text: list.name);
  int get have => songs.where((x) => x.$2 != null && !x.$2!.isLookup).length;
  int get toGet => songs.where((x) => x.$2 != null && x.$2!.isLookup).length;
  List<ImportEntry> get missing => [for (final (e, s) in songs) if (s == null) e];
}

class _ImportPlaylistScreenState extends ConsumerState<ImportPlaylistScreen> {
  List<_Matched> _lists = const [];
  String? _problem;
  bool _matching = false, _making = false, _getMissing = true;
  int _done = 0, _total = 0;

  Future<void> _pick() async {
    final r = await FilePicker.pickFiles(
      dialogTitle: 'A playlist exported from another app',
      type: FileType.custom,
      allowedExtensions: ['csv', 'tsv', 'json', 'm3u', 'm3u8', 'txt'],
    );
    final f = r.firstOrNull;
    if (f == null) return;
    final bytes = await f.readAsBytes();
    final lists = parsePlaylistFile(f.name, utf8.decode(bytes, allowMalformed: true));
    setState(() {
      _problem = lists.every((l) => l.entries.isEmpty) ? 'No songs found in ${f.name}' : null;
      _lists = [for (final l in lists) if (l.entries.isNotEmpty) _Matched(l)];
      if (_lists.length > 1) {
        for (final l in _lists) {
          l.chosen = false; // several (Spotify's data download): you pick
        }
      }
    });
  }

  Future<void> _match() async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    final chosen = _lists.where((l) => l.chosen).toList();
    setState(() {
      _matching = true;
      _done = 0;
      _total = chosen.fold(0, (n, l) => n + l.list.entries.length);
    });
    for (final l in chosen) {
      l.songs.clear();
      for (final e in l.list.entries) {
        if (!mounted) return;
        l.songs.add((e, await matchEntry(c, e)));
        setState(() => _done++);
      }
    }
    if (mounted) setState(() => _matching = false);
  }

  Future<void> _make() async {
    final c = ref.read(clientProvider);
    if (c == null) return;
    setState(() => _making = true);
    var made = 0;
    try {
      for (final l in _lists.where((l) => l.chosen && l.songs.isNotEmpty)) {
        final ids = <String>[
          for (final (_, s) in l.songs)
            if (s != null && (!s.isLookup || _getMissing)) s.id,
        ];
        if (ids.isEmpty) continue;
        await c.createPlaylist(l.name.text.trim().isEmpty ? l.list.name : l.name.text.trim(), ids);
        made++;
      }
      ref.invalidate(playlistsProvider);
      if (mounted) {
        toast(context, made == 1 ? 'Playlist made' : '$made playlists made');
        context.pop();
      }
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t make it: $e');
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final matched = _lists.any((l) => l.chosen && l.songs.isNotEmpty) && !_matching;
    return Scaffold(
      appBar: AppBar(title: const Text('Import a playlist')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'From another app\'s export: a CSV (Exportify, TuneMyMusic, Soundiiz…), Spotify\'s own "Download your data" '
            '(Playlist1.json, YourLibrary.json), an M3U playlist, or a text file with one "Artist - Title" a line.',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.upload_file_rounded),
            label: Text(_lists.isEmpty ? 'Choose the file' : 'Choose another file'),
            onPressed: _matching || _making ? null : _pick,
          ),
          if (_problem != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_problem!)),
          for (final l in _lists) ...[
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: l.chosen,
              onChanged: _matching || _making ? null : (v) => setState(() => l.chosen = v ?? false),
              title: Text(l.list.name),
              subtitle: Text(l.songs.isEmpty
                  ? nSongs(l.list.entries.length)
                  : '${l.have} in your library · ${l.toGet} to get · ${l.missing.length} not found'),
            ),
            if (l.chosen && l.songs.isNotEmpty) ...[
              TextField(controller: l.name, decoration: const InputDecoration(labelText: 'Name on your server')),
              if (l.missing.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Not found (${l.missing.length})', style: t.bodyMedium),
                  children: [for (final e in l.missing) ListTile(dense: true, title: Text(e.title), subtitle: Text(e.artist))],
                ),
            ],
          ],
          if (_lists.isNotEmpty) ...[
            const SizedBox(height: 16),
            if (_matching)
              Column(
                children: [
                  LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
                  const SizedBox(height: 6),
                  Text('Looking for each song on your server: $_done of $_total'),
                ],
              )
            else if (!matched)
              FilledButton.icon(
                icon: const Icon(Icons.search_rounded),
                label: const Text('Find them on my server'),
                onPressed: _lists.any((l) => l.chosen) && ref.watch(repoProvider).online ? _match : null,
              )
            else ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _getMissing,
                onChanged: (v) => setState(() => _getMissing = v),
                title: const Text('Get the songs I don\'t have'),
                subtitle: const Text('Your server downloads them into your library, then they join the playlist'),
              ),
              FilledButton.icon(
                icon: _making
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.playlist_add_check_rounded),
                label: const Text('Make the playlists'),
                onPressed: _making ? null : _make,
              ),
            ],
          ],
        ],
      ),
    );
  }
}
