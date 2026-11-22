import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../data/account.dart';
import '../data/song_id.dart';
import '../data/subsonic.dart';
import 'widgets.dart';
import 'sheets.dart';

/// "What's playing?" (Search): listen for 10 s, then show your song, or say it isn't one of yours.
Future<void> showWhatsPlaying(BuildContext context) => showAppSheet(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => const _WhatsPlaying(),
);

class _WhatsPlaying extends ConsumerStatefulWidget {
  const _WhatsPlaying();
  @override
  ConsumerState<_WhatsPlaying> createState() => _WhatsPlayingState();
}

class _WhatsPlayingState extends ConsumerState<_WhatsPlaying> {
  int? _left; // seconds still to listen; null: not listening
  bool _asking = false;
  Identification? _result;
  String? _problem;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
  }

  Future<void> _listen() async {
    final c = ref.read(clientProvider);
    if (c == null) return setState(() => _problem = 'Sign in to your server first');
    setState(() {
      _result = null;
      _problem = null;
      _left = recordSeconds;
    });
    try {
      final r = await whatsPlaying(c, cancelled: () => !mounted, onTick: (l) {
        if (mounted) setState(() => _left = l);
      });
      if (!mounted) return;
      setState(() {
        _left = null;
        _asking = false;
        if (r == null) {
          _problem = 'Encore needs the microphone for this. Allow it and try again';
        } else {
          _result = r;
        }
      });
    } on SubsonicException catch (e) {
      if (mounted) {
        setState(() {
          _left = null;
          _problem = e.code == 70 ? 'Your server can\'t recognise songs (Pitch needs Conductor or music-lookup with song-id)' : '$e';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _left = null;
          _problem = isDesktop ? 'Couldn\'t record what this computer plays ($e)' : 'Couldn\'t record ($e)';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = _result;
    final history = identifiedSongs();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Pitch · What\'s playing?', style: t.titleLarge),
            const SizedBox(height: 4),
            Text(
              isDesktop ? 'Listens to what this computer is playing' : 'Listens with the microphone, among your songs',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            if (_left != null) ...[
              Center(
                child: SizedBox(
                  width: 96,
                  height: 96,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(value: 1 - (_left! - 1) / recordSeconds, strokeWidth: 6),
                      Icon(Icons.hearing_rounded, size: 40, color: cs.primary),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(child: Text(_left! > 1 ? 'Listening… $_left s' : 'Looking among your songs…')),
            ] else if (_problem != null)
              ListTile(leading: const Icon(Icons.error_outline_rounded), title: Text(_problem!))
            else if (r != null && r.found)
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        child: Text('It\'s one of yours', style: t.labelLarge?.copyWith(color: cs.primary)),
                      ),
                      SongTile(r.song!),
                    ],
                  ),
                ),
              )
            else if (r != null)
              ListTile(
                leading: const Icon(Icons.search_off_rounded),
                title: const Text('Not one of your songs'),
                subtitle: Text(r.indexing
                    ? 'Your server is still learning your library (${r.songs} songs so far): it may be one it hasn\'t got to'
                    : 'Only songs in your library are recognised. Try again closer to the sound'),
              ),
            if (_left == null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: _asking ? null : _listen,
                icon: const Icon(Icons.hearing_rounded),
                label: Text(r == null && _problem == null ? 'Listen' : 'Listen again'),
              ),
            ],
            if (history.isNotEmpty && _left == null) ...[
              const SizedBox(height: 16),
              Text('Identified before', style: t.titleSmall),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(
                  shrinkWrap: true,
                  children: [for (final (s, _) in history.take(20)) SongTile(s)],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// For tests: what the sheet would show for an answer.
String identificationSummary(Identification r) => r.found
    ? '${r.song!.title} · ${r.song!.artist}'
    : r.indexing
    ? 'not yet'
    : 'not yours';
