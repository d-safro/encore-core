import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/account.dart';
import '../actions.dart';
import '../state.dart';

/// Smart playlists are Navidrome's own: it keeps them filled from the rules, for every app.
enum _Kind { text, number, bool, date }

const _fields = <String, (String, _Kind)>{
  'title': ('Title', _Kind.text),
  'artist': ('Artist', _Kind.text),
  'albumartist': ('Album artist', _Kind.text),
  'album': ('Album', _Kind.text),
  'genre': ('Genre', _Kind.text),
  'year': ('Year', _Kind.number),
  'rating': ('Stars', _Kind.number),
  'loved': ('Hearted', _Kind.bool),
  'playcount': ('Times played', _Kind.number),
  'lastplayed': ('Last played', _Kind.date),
  'dateadded': ('Added', _Kind.date),
  'dateloved': ('Hearted on', _Kind.date),
  'duration': ('Length (seconds)', _Kind.number),
  'bitrate': ('Bitrate (kbps)', _Kind.number),
  'filetype': ('File type', _Kind.text),
  'compilation': ('Compilation', _Kind.bool),
};

const _ops = <_Kind, Map<String, String>>{
  _Kind.text: {'contains': 'contains', 'notContains': "doesn't contain", 'is': 'is', 'isNot': "isn't", 'startsWith': 'starts with'},
  _Kind.number: {'is': 'is', 'isNot': "isn't", 'gt': 'more than', 'lt': 'less than', 'inTheRange': 'between'},
  _Kind.bool: {'is': 'is'},
  _Kind.date: {'inTheLast': 'in the last (days)', 'notInTheLast': 'not in the last (days)', 'after': 'after', 'before': 'before'},
};

const _sorts = <String, String>{
  'random': 'Shuffled',
  'playcount': 'Most played',
  'lastplayed': 'Last played',
  'dateadded': 'Recently added',
  'rating': 'Stars',
  'title': 'Title',
  'artist': 'Artist',
  'album': 'Album',
  'year': 'Year',
};

/// Ready-made smart playlists: (name, what it is, rules).
final smartPresets = <(String, String, Map<String, dynamic>)>[
  (
    'Forgotten favourites',
    "Hearted, but not played in 6 months",
    {
      'all': [
        {'is': {'loved': true}},
        {'notInTheLast': {'lastplayed': 180}},
      ],
      'sort': 'random',
      'limit': 100,
    },
  ),
  (
    'Added this month',
    'Everything new in the last 30 days',
    {
      'all': [
        {'inTheLast': {'dateadded': 30}},
      ],
      'sort': 'dateadded',
      'order': 'desc',
    },
  ),
  (
    'Four stars and up',
    'Songs you rated 4 or 5',
    {
      'all': [
        {'gt': {'rating': 3}},
      ],
      'sort': 'rating',
      'order': 'desc',
    },
  ),
  (
    'On repeat',
    'Your most played of the last month',
    {
      'all': [
        {'inTheLast': {'lastplayed': 30}},
        {'gt': {'playcount': 2}},
      ],
      'sort': 'playcount',
      'order': 'desc',
      'limit': 50,
    },
  ),
  (
    'Most played ever',
    'Your top 100',
    {
      'all': [
        {'gt': {'playcount': 0}},
      ],
      'sort': 'playcount',
      'order': 'desc',
      'limit': 100,
    },
  ),
  (
    'Never played',
    "In your library, but you've never played it",
    {
      'all': [
        {'is': {'playcount': 0}},
      ],
      'sort': 'random',
      'limit': 200,
    },
  ),
];

/// "New playlist": an ordinary one, a smart one from a preset, or your own rules.
Future<void> showNewPlaylistSheet(BuildContext context, WidgetRef ref) async {
  final pick = await showModalBottomSheet<Object>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: const Text('Playlist'),
              subtitle: const Text('You choose the songs'),
              onTap: () => Navigator.pop(ctx, 'plain'),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_motion_rounded),
              title: const Text('Smart playlist'),
              subtitle: const Text('Fills itself from rules you set, and stays up to date'),
              onTap: () => Navigator.pop(ctx, 'smart'),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Or start from one of these'),
            ),
            for (final p in smartPresets)
              ListTile(
                leading: const Icon(Icons.bolt_rounded),
                title: Text(p.$1),
                subtitle: Text(p.$2),
                onTap: () => Navigator.pop(ctx, p),
              ),
          ],
        ),
      ),
    ),
  );
  if (pick == null || !context.mounted) return;
  if (pick == 'plain') {
    final name = await askText(context, 'New playlist', 'Name');
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(clientProvider)?.createPlaylist(name, const []);
      ref.invalidate(playlistsProvider);
    } catch (e) {
      if (context.mounted) toast(context, "Couldn't create the playlist: $e");
    }
  } else if (pick == 'smart') {
    await Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute(builder: (_) => const SmartPlaylistScreen()));
  } else if (pick is (String, String, Map<String, dynamic>)) {
    try {
      final id = await ref.read(clientProvider)!.createSmartPlaylist(pick.$1, pick.$3, comment: pick.$2);
      ref.invalidate(playlistsProvider);
      if (context.mounted) context.push('/playlist/$id');
    } catch (e) {
      if (context.mounted) toast(context, "Couldn't create it: $e");
    }
  }
}

class _Rule {
  _Rule(this.field, this.op, this.value);
  String field, op, value;
}

/// Make or change a smart playlist's rules.
class SmartPlaylistScreen extends ConsumerStatefulWidget {
  const SmartPlaylistScreen({super.key, this.id, this.name = '', this.rules});
  final String? id;
  final String name;
  final Map<String, dynamic>? rules;
  @override
  ConsumerState<SmartPlaylistScreen> createState() => _SmartPlaylistScreenState();
}

class _SmartPlaylistScreenState extends ConsumerState<SmartPlaylistScreen> {
  late final _name = TextEditingController(text: widget.name);
  late final _limit = TextEditingController();
  bool _any = false;
  String _sort = 'random';
  bool _desc = false;
  final _rules = <_Rule>[];
  final _kept = <Map<String, dynamic>>[]; // rules this screen can't show (groups): kept as they are
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final r = widget.rules;
    if (r == null) {
      _rules.add(_Rule('loved', 'is', 'true'));
      return;
    }
    _any = r.containsKey('any');
    for (final x in (r[_any ? 'any' : 'all'] as List? ?? const [])) {
      final m = (x as Map).cast<String, dynamic>();
      final op = m.keys.first;
      final inner = m[op];
      if (inner is Map && inner.length == 1 && _fields.containsKey(inner.keys.first)) {
        final v = inner.values.first;
        _rules.add(_Rule('${inner.keys.first}', op, v is List ? v.join('-') : '$v'));
      } else {
        _kept.add(m);
      }
    }
    _sort = _sorts.containsKey(r['sort']) ? r['sort'] as String : 'random';
    _desc = r['order'] == 'desc';
    if (r['limit'] is num && r['limit'] > 0) _limit.text = '${r['limit']}';
  }

  @override
  void dispose() {
    _name.dispose();
    _limit.dispose();
    super.dispose();
  }

  Object _typed(_Rule r) {
    final kind = _fields[r.field]!.$2;
    final v = r.value.trim();
    if (kind == _Kind.bool) return v == 'true';
    if (r.op == 'inTheRange') {
      final parts = v.split(RegExp(r'\s*[-–,]\s*')).map(num.tryParse).whereType<num>().toList();
      return parts.length == 2 ? parts : [0, num.tryParse(v) ?? 0];
    }
    if (kind == _Kind.number || r.op == 'inTheLast' || r.op == 'notInTheLast') return num.tryParse(v) ?? 0;
    return v;
  }

  Map<String, dynamic> _json() => {
    _any ? 'any' : 'all': [
      for (final r in _rules)
        {
          r.op: {r.field: _typed(r)},
        },
      ..._kept,
    ],
    'sort': _sort,
    if (_sort != 'random') 'order': _desc ? 'desc' : 'asc',
    if ((int.tryParse(_limit.text) ?? 0) > 0) 'limit': int.parse(_limit.text),
  };

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return toast(context, 'Give it a name');
    if (_rules.isEmpty && _kept.isEmpty) return toast(context, 'Add at least one rule');
    final c = ref.read(clientProvider);
    if (c == null) return;
    setState(() => _saving = true);
    try {
      if (widget.id == null) {
        final id = await c.createSmartPlaylist(name, _json());
        ref.invalidate(playlistsProvider);
        if (!mounted) return;
        Navigator.pop(context);
        context.push('/playlist/$id');
      } else {
        await c.updateSmartPlaylist(widget.id!, name, _json());
        ref.invalidate(playlistsProvider);
        ref.invalidate(playlistProvider(widget.id!));
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) toast(context, "Couldn't save: $e");
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _ruleRow(_Rule r) {
    final kind = _fields[r.field]!.$2;
    final ops = _ops[kind]!;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    value: r.field,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    items: [for (final e in _fields.entries) DropdownMenuItem(value: e.key, child: Text(e.value.$1))],
                    onChanged: (f) => setState(() {
                      final k = _fields[f]!.$2;
                      r.field = f!;
                      if (!_ops[k]!.containsKey(r.op)) r.op = _ops[k]!.keys.first;
                      if (k == _Kind.bool) r.value = 'true';
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    value: r.op,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    items: [for (final e in ops.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                    onChanged: (o) => setState(() => r.op = o!),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(() => _rules.remove(r)),
                ),
              ],
            ),
            if (kind == _Kind.bool)
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'true', label: Text('Yes')),
                  ButtonSegment(value: 'false', label: Text('No')),
                ],
                selected: {r.value == 'false' ? 'false' : 'true'},
                onSelectionChanged: (v) => setState(() => r.value = v.first),
              )
            else
              TextFormField(
                initialValue: r.value,
                keyboardType: kind == _Kind.text || r.op == 'after' || r.op == 'before'
                    ? TextInputType.text
                    : TextInputType.number,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: switch (r.op) {
                    'inTheRange' => 'e.g. 1970-1979',
                    'after' || 'before' => 'a date, e.g. 2024-01-31',
                    'inTheLast' || 'notInTheLast' => 'days, e.g. 30',
                    _ => kind == _Kind.number ? 'a number' : 'text',
                  },
                ),
                onChanged: (v) => r.value = v,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.id == null ? 'New smart playlist' : 'Smart playlist'),
        actions: [
          TextButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Match all rules')),
                ButtonSegment(value: true, label: Text('Match any')),
              ],
              selected: {_any},
              onSelectionChanged: (v) => setState(() => _any = v.first),
            ),
          ),
          for (final r in _rules) _ruleRow(r),
          if (_kept.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('${_kept.length} more advanced rule(s) set elsewhere are kept as they are.'),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add a rule'),
                onPressed: () => setState(() => _rules.add(_Rule('artist', 'contains', ''))),
              ),
            ),
          ),
          const Divider(height: 32),
          ListTile(
            title: const Text('Order'),
            trailing: DropdownButton<String>(
              value: _sort,
              underline: const SizedBox.shrink(),
              items: [for (final e in _sorts.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => setState(() => _sort = v!),
            ),
          ),
          if (_sort != 'random')
            SwitchListTile(
              title: const Text('Highest / newest first'),
              value: _desc,
              onChanged: (v) => setState(() => _desc = v),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _limit,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'At most this many songs (empty: no limit)'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Your server keeps this playlist up to date by itself, and it shows in your other apps too. '
              'Songs can\'t be added to it by hand.',
            ),
          ),
        ],
      ),
    );
  }
}
