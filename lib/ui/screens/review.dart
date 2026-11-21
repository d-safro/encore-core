import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/platform.dart';
import '../../data/account.dart';
import '../../data/library.dart';
import '../../data/review.dart';
import '../actions.dart' show toast;
import '../widgets.dart';
import 'player.dart' show artSchemeProvider;

/// Your year (or month) in review: a story of cards that moves on by itself (tap the right side for the next,
/// the left for the one before, hold to pause), coloured from each card's artwork, ending with a card to share.
final reviewProvider = FutureProvider.autoDispose.family<ListeningReview, (String, int)>((ref, k) async {
  ref.cacheFor(const Duration(minutes: 30));
  final c = ref.watch(clientProvider);
  if (c == null || !ref.watch(repoProvider).online) throw Exception('Your year in review needs your server');
  return c.listeningReview(k.$1, offset: k.$2);
});

const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
    'November', 'December'];

/// "2026", or "November 2026" for a month.
String reviewTitle(String period, int offset, [DateTime? now]) {
  final n = now ?? DateTime.now();
  if (period == 'month') {
    final d = DateTime(n.year, n.month - offset);
    return '${_months[d.month - 1]} ${d.year}';
  }
  return '${n.year - offset}';
}

class ReviewScreen extends ConsumerWidget {
  const ReviewScreen({super.key, this.period = 'year', this.offset = 0});
  final String period;
  final int offset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(reviewProvider((period, offset)));
    return Scaffold(
      backgroundColor: Colors.black,
      body: r.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Message('$e', onClose: () => context.pop()),
        data: (v) => v.isEmpty
            ? _Message('No plays in ${reviewTitle(period, offset)} yet', onClose: () => context.pop())
            : _Story(review: v, title: reviewTitle(period, offset)),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {required this.onClose});
  final String text;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Stack(
      children: [
        Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(text, textAlign: TextAlign.center))),
        Align(
          alignment: Alignment.topRight,
          child: IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: onClose),
        ),
      ],
    ),
  );
}

/// One card: its art (for the colours), and what it shows.
class _Card {
  const _Card(this.art, this.build);
  final String art;
  final Widget Function(BuildContext context) build;
}

class _Story extends ConsumerStatefulWidget {
  const _Story({required this.review, required this.title});
  final ListeningReview review;
  final String title;
  @override
  ConsumerState<_Story> createState() => _StoryState();
}

class _StoryState extends ConsumerState<_Story> with SingleTickerProviderStateMixin {
  late final _timer = AnimationController(vsync: this, duration: const Duration(seconds: 7))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _go(1);
    });
  final _pages = PageController();
  int _page = 0;
  late final List<_Card> _cards = _makeCards();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // the phone's "Remove animations": no moving on by itself, tap through instead
    if (!MediaQuery.disableAnimationsOf(context) && !_timer.isAnimating && _page < _cards.length - 1) {
      _timer.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _timer.dispose();
    _pages.dispose();
    super.dispose();
  }

  void _go(int d) {
    final to = (_page + d).clamp(0, _cards.length - 1);
    if (to == _page) {
      if (d > 0) _timer.stop(); // the last card stays
      return;
    }
    _pages.jumpToPage(to);
  }

  void _onPage(int i) {
    setState(() => _page = i);
    _timer.value = 0;
    // the last card (share) stays until you leave
    if (i < _cards.length - 1 && !MediaQuery.disableAnimationsOf(context)) _timer.forward(from: 0);
  }

  List<_Card> _makeCards() {
    final r = widget.review, s = r.stats;
    final topArtist = s.artists.isEmpty ? null : s.artists.first;
    final topSong = s.songs.isEmpty ? null : s.songs.first;
    final topAlbum = s.albums.isEmpty ? null : s.albums.first;
    return [
      _Card(topAlbum?.$1.coverArt ?? '', (c) => _Big(
        kicker: 'Your ${widget.title}',
        big: thousands(s.minutes),
        line: 'minutes of music',
        more: '${thousands(s.plays)} plays · ${thousands(s.songCount)} songs · ${thousands(s.artistCount)} artists',
      )),
      if (topArtist != null)
        _Card(topArtist.$1.coverArt, (c) => _Top(
          kicker: 'Your top artist',
          cover: topArtist.$1.coverArt,
          circle: true,
          name: topArtist.$1.name,
          sub: '${thousands(topArtist.$3)} minutes · ${thousands(topArtist.$2)} plays',
          rest: [for (final a in s.artists.skip(1).take(4)) (a.$1.coverArt, a.$1.name, '${thousands(a.$2)} plays')],
        )),
      if (topSong != null)
        _Card(topSong.$1.coverArt, (c) => _Top(
          kicker: 'Your top song',
          cover: topSong.$1.coverArt,
          name: topSong.$1.title,
          sub: '${topSong.$1.artist} · played ${thousands(topSong.$2)} times',
          rest: [for (final x in s.songs.skip(1).take(4)) (x.$1.coverArt, x.$1.title, x.$1.artist)],
        )),
      if (topAlbum != null)
        _Card(topAlbum.$1.coverArt, (c) => _Top(
          kicker: 'Your top album',
          cover: topAlbum.$1.coverArt,
          name: topAlbum.$1.name,
          sub: '${topAlbum.$1.artist} · ${thousands(topAlbum.$2)} plays',
          rest: [for (final x in s.albums.skip(1).take(4)) (x.$1.coverArt, x.$1.name, x.$1.artist)],
        )),
      if (r.genres.isNotEmpty)
        _Card(topSong?.$1.coverArt ?? '', (c) => _Big(
          kicker: 'Your top genre',
          big: r.genres.first.$1,
          line: '${thousands(r.genres.first.$2)} minutes',
          more: r.genres.skip(1).map((g) => g.$1).join(' · '),
        )),
      if (r.firstSong case final f?)
        _Card(f.coverArt, (c) => _Top(kicker: 'It started with', cover: f.coverArt, name: f.title, sub: f.artist)),
      if (r.streakDays >= 2)
        _Card(topArtist?.$1.coverArt ?? '', (c) => _Big(
          kicker: 'Your longest streak',
          big: '${r.streakDays}',
          line: 'days in a row with music',
          more: r.streakFrom == null ? '' : 'from ${r.streakFrom!.day} ${_months[r.streakFrom!.month - 1]}',
        )),
      if (r.peakHour case final h?)
        _Card(topAlbum?.$1.coverArt ?? '', (c) => _Big(
          kicker: 'Your hour',
          big: hourLabel(h),
          line: 'is when you listened most',
          bars: s.hours,
        )),
      if (r.discoveries.isNotEmpty || (s.newArtists ?? 0) > 0)
        _Card(r.discoveries.isEmpty ? '' : r.discoveries.first.$1.coverArt, (c) => _Top(
          kicker: 'Found and kept',
          cover: r.discoveries.isEmpty ? '' : r.discoveries.first.$1.coverArt,
          name: r.discoveries.isEmpty ? '${s.newArtists} new artists' : r.discoveries.first.$1.title,
          sub: r.discoveries.isEmpty
              ? 'heard for the first time'
              : '${r.discoveries.first.$1.artist} · new to you, played ${r.discoveries.first.$2} times',
          rest: [for (final x in r.discoveries.skip(1).take(4)) (x.$1.coverArt, x.$1.title, x.$1.artist)],
          foot: (s.newArtists ?? 0) > 0 ? '${s.newArtists} artists you hadn\'t heard before' : null,
        )),
      _Card(topArtist?.$1.coverArt ?? topAlbum?.$1.coverArt ?? '', (c) => _ShareCardPage(review: r, title: widget.title)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final art = _cards[_page].art;
    final scheme = ref.watch(artSchemeProvider(art)).value ?? Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => _go(d.localPosition.dx < MediaQuery.sizeOf(context).width / 3 ? -1 : 1),
      onLongPressStart: (_) => _timer.stop(),
      onLongPressEnd: (_) {
        if (_page < _cards.length - 1 && !MediaQuery.disableAnimationsOf(context)) _timer.forward();
      },
      child: _Backdrop(
        scheme: scheme,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: Row(
                  children: [
                    for (var i = 0; i < _cards.length; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: AnimatedBuilder(
                            animation: _timer,
                            builder: (_, _) => LinearProgressIndicator(
                              value: i < _page ? 1 : (i == _page ? _timer.value : 0),
                              minHeight: 3,
                              borderRadius: BorderRadius.circular(2),
                              color: Colors.white,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                      onPressed: () => context.pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Semantics(
                  label: 'Card ${_page + 1} of ${_cards.length}',
                  customSemanticsActions: {
                    const CustomSemanticsAction(label: 'Next card'): () => _go(1),
                    const CustomSemanticsAction(label: 'Previous card'): () => _go(-1),
                  },
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: _cards.length,
                    onPageChanged: _onPage,
                    itemBuilder: (ctx, i) => _cards[i].build(ctx),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The colours of a card: a deep gradient from its art, white words.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.scheme, required this.child});
  final ColorScheme scheme;
  final Widget child;
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 500),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color.lerp(scheme.primary, Colors.black, 0.35)!, Color.lerp(scheme.tertiary, Colors.black, 0.75)!],
      ),
    ),
    child: DefaultTextStyle.merge(style: const TextStyle(color: Colors.white), child: child),
  );
}

/// A number or a word, big.
class _Big extends StatelessWidget {
  const _Big({required this.kicker, required this.big, required this.line, this.more = '', this.bars});
  final String kicker, big, line, more;
  final List<int>? bars;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(kicker, style: t.titleMedium?.copyWith(color: Colors.white70)),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(big, style: t.displayLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
          ),
          Text(line, style: t.headlineSmall?.copyWith(color: Colors.white)),
          if (more.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(more, style: t.bodyLarge?.copyWith(color: Colors.white70)),
          ],
          if (bars != null && bars!.isNotEmpty) ...[
            const SizedBox(height: 24),
            SizedBox(height: 80, child: _HourBars(bars!)),
          ],
        ],
      ),
    );
  }
}

class _HourBars extends StatelessWidget {
  const _HourBars(this.hours);
  final List<int> hours;
  @override
  Widget build(BuildContext context) {
    final top = hours.fold(1, (a, b) => b > a ? b : a);
    return ExcludeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final h in hours)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: FractionallySizedBox(
                  heightFactor: (h / top).clamp(0.03, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: h == top ? Colors.white : Colors.white38,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A big cover and name, then the next four.
class _Top extends StatelessWidget {
  const _Top({
    required this.kicker,
    required this.cover,
    required this.name,
    required this.sub,
    this.rest = const [],
    this.circle = false,
    this.foot,
  });
  final String kicker, cover, name, sub;
  final List<(String, String, String)> rest; // cover, name, sub
  final bool circle;
  final String? foot;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, box) {
        final size = (box.maxWidth - 64).clamp(120.0, rest.isEmpty ? 360.0 : 220.0);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(kicker, style: t.titleMedium?.copyWith(color: Colors.white70)),
              const SizedBox(height: 16),
              if (cover.isNotEmpty)
                Cover(cover, size: size, radius: 16, circle: circle, icon: Icons.music_note_rounded, artistImage: circle),
              const SizedBox(height: 16),
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: t.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
              Text(sub, style: t.bodyLarge?.copyWith(color: Colors.white70)),
              if (rest.isNotEmpty) const SizedBox(height: 20),
              for (final (i, r) in rest.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(width: 28, child: Text('${i + 2}', style: t.titleMedium?.copyWith(color: Colors.white70))),
                      Cover(r.$1, size: 40, radius: circle ? 20 : 6, circle: circle, artistImage: circle),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.$2, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: t.bodyLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
                            Text(r.$3, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: t.bodySmall?.copyWith(color: Colors.white70)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (foot != null) ...[
                const SizedBox(height: 16),
                Text(foot!, style: t.bodyLarge?.copyWith(color: Colors.white70)),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ── Sharing ──
/// The last card: a preview of the picture to share, square or 9:16.
class _ShareCardPage extends StatefulWidget {
  const _ShareCardPage({required this.review, required this.title});
  final ListeningReview review;
  final String title;
  @override
  State<_ShareCardPage> createState() => _ShareCardPageState();
}

class _ShareCardPageState extends State<_ShareCardPage> {
  final _key = GlobalKey();
  bool _story = true; // 9:16, else square
  bool _busy = false;

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final box = _key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (box == null) return;
      final img = await box.toImage(pixelRatio: 1080 / box.size.width); // 1080 px wide
      final png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      final name = 'encore-${widget.title.replaceAll(' ', '-').toLowerCase()}-${_story ? 'story' : 'square'}.png';
      if (isDesktop) {
        // the desktop can't share a file: save it to Downloads
        final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
        final f = File('${dir.path}/$name');
        await f.writeAsBytes(png);
        if (mounted) toast(context, 'Saved to ${f.path}');
      } else {
        final f = File('${(await getTemporaryDirectory()).path}/$name');
        await f.writeAsBytes(png);
        await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'image/png')], text: 'My ${widget.title} on Encore'));
      }
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t make the picture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
    child: Column(
      children: [
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: _story ? 9 / 16 : 1,
              child: RepaintBoundary(key: _key, child: ShareCard(review: widget.review, title: widget.title, story: _story)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // taps here are for these buttons, not for moving between cards
        GestureDetector(
          onTapUp: (_) {},
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Story'), icon: Icon(Icons.crop_portrait_rounded)),
                  ButtonSegment(value: false, label: Text('Square'), icon: Icon(Icons.crop_square_rounded)),
                ],
                selected: {_story},
                onSelectionChanged: (v) => setState(() => _story = v.first),
              ),
              FilledButton.icon(
                onPressed: _busy ? null : _share,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(isDesktop ? Icons.download_rounded : Icons.share_rounded),
                label: Text(isDesktop ? 'Save picture' : 'Share'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The picture: your year in a few lines over your top artist's colours.
class ShareCard extends ConsumerWidget {
  const ShareCard({super.key, required this.review, required this.title, this.story = true});
  final ListeningReview review;
  final String title;
  final bool story;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = review.stats;
    final art = s.artists.isNotEmpty ? s.artists.first.$1.coverArt : (s.albums.isNotEmpty ? s.albums.first.$1.coverArt : '');
    final scheme = ref.watch(artSchemeProvider(art)).value ?? Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final u = box.maxWidth / 360; // everything scales with the card's width
        TextStyle st(double size, {FontWeight w = FontWeight.w600, Color c = Colors.white}) =>
            TextStyle(fontSize: size * u, fontWeight: w, color: c, height: 1.15);
        Widget list(String head, List<String> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(head, style: st(12, c: Colors.white70)),
            SizedBox(height: 4 * u),
            for (final (i, x) in items.indexed)
              Text('${i + 1}  $x', maxLines: 1, overflow: TextOverflow.ellipsis, style: st(story ? 15 : 13)),
          ],
        );
        return ClipRRect(
          borderRadius: BorderRadius.circular(20 * u),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color.lerp(scheme.primary, Colors.black, 0.25)!, Color.lerp(scheme.tertiary, Colors.black, 0.8)!],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.all(24 * u),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('My $title', style: st(story ? 28 : 22, w: FontWeight.w800)),
                  SizedBox(height: 12 * u),
                  if (art.isNotEmpty)
                    Center(child: Cover(art, size: (story ? 200 : 110) * u, radius: 12 * u, artistImage: s.artists.isNotEmpty)),
                  SizedBox(height: 16 * u),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: list('Top artists', [for (final a in s.artists.take(5)) a.$1.name])),
                        SizedBox(width: 12 * u),
                        Expanded(child: list('Top songs', [for (final x in s.songs.take(5)) x.$1.title])),
                      ],
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Minutes listened', style: st(12, c: Colors.white70)),
                            Text(thousands(s.minutes), style: st(story ? 34 : 26, w: FontWeight.w800)),
                          ],
                        ),
                      ),
                      if (review.genres.isNotEmpty)
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Top genre', style: st(12, c: Colors.white70)),
                              Text(review.genres.first.$1, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: st(story ? 22 : 18, w: FontWeight.w800)),
                            ],
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: 10 * u),
                  Text('ENCORE', style: st(11, w: FontWeight.w800, c: Colors.white54).copyWith(letterSpacing: 3 * u)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
