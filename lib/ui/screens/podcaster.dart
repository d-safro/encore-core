import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/artist_extra.dart' show normName;
import '../../data/cover_cache.dart';
import '../../data/library.dart';
import '../../data/models.dart';
import '../../data/podcaster.dart';
import '../../data/updates.dart' show openUrl;
import '../../playback/handler.dart';
import '../widgets.dart';
import 'podcasts.dart';

/// Looks up a podcaster: the phone's copy when it's fresh or when offline, otherwise online (and kept).
/// Key: (name, first feed address of their shows you follow, your show titles joined by \n).
final podcasterProvider = FutureProvider.autoDispose.family<PodcasterInfo, (String, String, String)>((ref, k) async {
  ref.cacheFor(const Duration(minutes: 15));
  final (name, feed, mine) = k;
  final (cached, fresh) = cachedPodcaster(name);
  if (cached != null && fresh) return cached;
  if (!ref.watch(repoProvider).online) return cached ?? const PodcasterInfo();
  final info = await fetchPodcaster(
    name,
    feeds: [if (feed.isNotEmpty) feed],
    myShows: mine.isEmpty ? const [] : mine.split('\n'),
  );
  return info.isEmpty ? (cached ?? info) : info;
});

/// A podcast's maker, like an artist page: picture, about, links, their shows you follow, their latest episodes,
/// and their other shows in Apple's directory. Opened with a [name] (the show's author), a [showId], or both;
/// a show with no author stands for itself.
class PodcasterScreen extends ConsumerStatefulWidget {
  const PodcasterScreen({super.key, this.name = '', this.showId = ''});
  final String name, showId;
  @override
  ConsumerState<PodcasterScreen> createState() => _PodcasterScreenState();
}

class _PodcasterScreenState extends ConsumerState<PodcasterScreen> {
  final _title = ScrollTitle();
  bool _aboutOpen = false;
  final _adding = <String>{}, _added = <String>{};

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final online = ref.watch(repoProvider).online;
    final listAsync = ref.watch(podcastsProvider);
    final list = listAsync.value ?? const <PodcastChannel>[];
    // the show it was opened from (from the list of your shows; its own page when it isn't there)
    PodcastChannel? show = widget.showId.isEmpty ? null : list.where((p) => p.id == widget.showId).firstOrNull;
    if (widget.showId.isNotEmpty && show == null && !listAsync.isLoading) {
      show = ref.watch(podcastProvider(widget.showId)).value;
    }
    final name = widget.name.isNotEmpty
        ? widget.name
        : (show == null ? '' : (show.author.isNotEmpty ? show.author : show.title));
    final isShow = show != null && normName(name) == normName(show.title); // the show is its own maker
    final mine = [
      for (final p in list)
        if (p.id == widget.showId || sameMaker(p.author.isNotEmpty ? p.author : p.title, name)) p,
    ];
    if (show != null && !mine.any((p) => p.id == show!.id)) mine.insert(0, show);

    final ready = name.isNotEmpty && !listAsync.isLoading;
    final infoAsync = ready
        ? ref.watch(
            podcasterProvider((
              name,
              mine.map((p) => p.url).where((u) => u.isNotEmpty).firstOrNull ?? '',
              mine.map((p) => p.title).join('\n'),
            )),
          )
        : const AsyncLoading<PodcasterInfo>();
    final info = infoAsync.value ?? const PodcasterInfo();

    // their latest episodes, from the shows you follow (the phone's copy when offline)
    final episodes = <PodcastEpisode>[
      for (final p in mine.take(6)) ...?ref.watch(podcastProvider(p.id)).value?.episodes.take(10),
    ]..sort((a, b) => (b.published ?? DateTime(0)).compareTo(a.published ?? DateTime(0)));
    final next = episodes.where((e) => e.inProgress).firstOrNull ?? episodes.where((e) => !e.played).firstOrNull;

    final followedFeeds = {for (final p in list) p.url};
    final followedTitles = {for (final p in list) normName(p.title)};
    final (shows: others, :sure) = otherShows(
      info.shows,
      name,
      followedFeeds: followedFeeds,
      followedTitles: followedTitles,
    );

    final about = info.about.isNotEmpty ? info.about : (mine.length == 1 ? mine.first.description : '');
    final fromWiki = info.about.isNotEmpty;
    final picture = info.image;
    // when there's no picture of them: the show's artwork from Apple, else the newest episode's (or the show's) cover
    final showArt = mine.isEmpty
        ? (info.shows.firstOrNull?.artwork ?? '')
        : info.shows.where((s) => normName(s.title) == normName(mine.first.title)).firstOrNull?.artwork ?? '';
    final coverId = episodes.firstOrNull?.coverArt ?? mine.firstOrNull?.coverArt ?? '';
    // several people in one author line: a page for each of them
    final people = isShow ? const <String>[] : makerNames(name);
    final links = [
      if (info.website.isNotEmpty) (Icons.language_rounded, 'Website', info.website),
      if (info.wikiUrl.isNotEmpty) (Icons.menu_book_outlined, 'Wikipedia', info.wikiUrl),
      if (info.appleUrl.isNotEmpty) (Icons.podcasts_rounded, 'Apple Podcasts', info.appleUrl),
    ];

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: overArtBar(context),
        surfaceTintColor: Colors.transparent,
        title: _title.title(name),
      ),
      body: name.isEmpty
          ? (listAsync.isLoading || (widget.showId.isNotEmpty && ref.watch(podcastProvider(widget.showId)).isLoading)
                ? const Center(child: CircularProgressIndicator())
                : const Center(child: Text("Couldn't find this podcast")))
          : _title.wrap(
              ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  _Header(
                    name: name,
                    picture: picture.isNotEmpty ? picture : showArt,
                    coverId: coverId,
                    circle: picture.isNotEmpty && !isShow,
                    line: [
                      if (isShow) 'Podcast' else 'Podcaster',
                      if (mine.isNotEmpty) mine.length == 1 ? '1 show you follow' : '${mine.length} shows you follow',
                      if (others.isNotEmpty && sure) others.length == 1 ? '1 more show' : '${others.length} more shows',
                    ].join(' · '),
                  ),
                  if (next != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                      child: FilledButton.icon(
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          next.inProgress ? 'Resume: ${next.title}' : 'Play latest: ${next.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPressed: () => audioHandler.playEpisode(next),
                      ),
                    ),
                  if (links.isNotEmpty || people.length > 1)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (people.length > 1)
                            for (final person in people)
                              ActionChip(
                                avatar: const Icon(Icons.person_outline, size: 18),
                                label: Text(person),
                                onPressed: () => context.push(podcasterPath(name: person)),
                              ),
                          for (final (icon, label, url) in links)
                            ActionChip(
                              avatar: Icon(icon, size: 18),
                              label: Text(label),
                              onPressed: () => openUrl(url).catchError((_) {}),
                            ),
                        ],
                      ),
                    ),
                  if (about.isNotEmpty) ...[
                    const SectionTitle('About'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Material(
                        color: cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => setState(() => _aboutOpen = !_aboutOpen),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  about,
                                  maxLines: _aboutOpen ? null : 4,
                                  overflow: _aboutOpen ? null : TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _aboutOpen ? (fromWiki ? 'From Wikipedia' : '') : 'Read more',
                                  style: t.labelMedium?.copyWith(color: cs.primary),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (mine.isNotEmpty) ...[
                    SectionTitle(mine.length == 1 ? 'The show' : 'Shows you follow'),
                    for (final p in mine)
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                        leading: Cover(p.coverArt, size: 56, radius: 10, icon: Icons.podcasts_rounded),
                        title: Text(p.title, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (p.episodeCount > 0) '${p.episodeCount} episodes',
                            if (p.unplayed > 0) '${p.unplayed} new',
                          ].join(' · '),
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => context.push('/podcast/${p.id}'),
                      ),
                  ],
                  if (episodes.isNotEmpty) ...[
                    const SectionTitle('Latest episodes'),
                    for (final e in episodes.take(5)) EpisodeTile(e, showCover: mine.length > 1),
                  ],
                  if (others.isNotEmpty) ...[
                    SectionTitle(
                      sure ? (mine.isEmpty ? 'Shows' : 'More from $name') : 'Shows by people named $name',
                      subtitle: sure ? 'From Apple Podcasts' : 'From Apple Podcasts: some may be by someone else',
                    ),
                    for (final s in others.take(20)) _onlineShow(context, s, online),
                  ] else if (infoAsync.isLoading && online)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _onlineShow(BuildContext context, OnlineShow s, bool online) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final url = s.feedUrl;
    final placeholder = Container(
      width: 56,
      height: 56,
      color: cs.surfaceContainerHigh,
      child: Icon(Icons.podcasts_rounded, color: cs.onSurfaceVariant),
    );
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: s.artwork.isEmpty
            ? placeholder
            : CachedNetworkImage(
                imageUrl: s.artwork,
                cacheManager: coverCache,
                width: 56,
                height: 56,
                memCacheWidth: 168,
                fit: BoxFit.cover,
                placeholder: (_, _) => placeholder,
                errorWidget: (_, _, _) => placeholder,
              ),
      ),
      title: Text(s.title, style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [if (s.genre.isNotEmpty) s.genre, if (s.episodes != null) '${s.episodes} episodes'].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: !online || !url.startsWith('http')
          ? null
          : _added.contains(url)
          ? Icon(Icons.check_circle, color: cs.primary)
          : _adding.contains(url)
          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : IconButton(
              tooltip: 'Follow',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () async {
                setState(() => _adding.add(url));
                final ok = await followPodcast(context, ref, url, s.title);
                if (!mounted) return;
                setState(() {
                  _adding.remove(url);
                  if (ok) _added.add(url);
                });
              },
            ),
      onTap: s.appleUrl.isEmpty ? null : () => openUrl(s.appleUrl).catchError((_) {}),
    );
  }
}

/// Like the artist page's header: the picture (or the show's cover) over a blurred copy of it, then the name.
class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.picture,
    required this.coverId,
    required this.circle,
    required this.line,
  });
  final String name, picture, coverId, line;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final w = MediaQuery.sizeOf(context).width;
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final size = (w * 0.6).clamp(160.0, 300.0);
    final bg = Theme.of(context).scaffoldBackgroundColor;
    Widget art(double side, {bool fill = false}) {
      final fallback = Cover(
        coverId,
        size: side,
        radius: 0,
        icon: circle ? Icons.person_outline : Icons.podcasts_rounded,
      );
      if (picture.isEmpty) return fallback;
      return CachedNetworkImage(
        imageUrl: picture,
        cacheManager: coverCache,
        width: fill ? null : side,
        height: fill ? null : side,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50, tileMode: TileMode.decal),
                child: art(double.infinity, fill: true),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [bg.withValues(alpha: 0.35), bg.withValues(alpha: 0.85), bg],
                    stops: const [0, 0.7, 1],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, top + 4, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    shape: circle ? BoxShape.circle : BoxShape.rectangle,
                    borderRadius: circle ? null : BorderRadius.circular(18),
                    boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 40, offset: Offset(0, 16))],
                  ),
                  child: circle
                      ? ClipOval(child: art(size))
                      : ClipRRect(borderRadius: BorderRadius.circular(18), child: art(size)),
                ),
              ),
              const SizedBox(height: 22),
              Text(name, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5)),
              const SizedBox(height: 6),
              Text(line, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}
