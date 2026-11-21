import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/appearance.dart';
import 'core/platform.dart';
import 'core/settings.dart';
import 'data/follows.dart';
import 'data/episode_alerts.dart';
import 'data/account.dart';
import 'data/devices.dart';
import 'desktop/shell.dart';
import 'data/sync.dart';
import 'data/library.dart';
import 'data/local_link.dart';
import 'data/usb_link.dart';
import 'playback/handler.dart';
import 'ui/screens/following.dart';
import 'ui/screens/appearance.dart';
import 'ui/screens/browse.dart';
import 'ui/screens/discover.dart';
import 'ui/screens/home.dart';
import 'ui/screens/library.dart';
import 'ui/screens/podcaster.dart';
import 'ui/screens/podcasts.dart';
import 'ui/screens/login.dart';
import 'ui/screens/player.dart';
import 'ui/screens/search.dart';
import 'ui/screens/settings.dart';
import 'data/updates.dart';
import 'ui/state.dart';
import 'ui/screens/review.dart';
import 'ui/screens/stats.dart';
import 'ui/update.dart';
import 'ui/widgets.dart';

final _rootKey = GlobalKey<NavigatorState>();

/// Lets code outside a screen (the player) show a snackbar.
final messengerKey = GlobalKey<ScaffoldMessengerState>();

final routerProvider = Provider<GoRouter>((ref) {
  final signedIn = ValueNotifier<bool?>(null);
  ref.listen(
    accountProvider,
    (_, next) => signedIn.value = next.isLoading ? null : next.value != null,
    fireImmediately: true,
  );
  return GoRouter(
    navigatorKey: _rootKey,
    // debug builds can start on another page (visual checks: ENCORE_START=/settings)
    initialLocation: kDebugMode && isDesktop ? (Platform.environment['ENCORE_START'] ?? '/home') : '/home',
    refreshListenable: signedIn,
    redirect: (ctx, state) {
      final s = signedIn.value;
      if (s == null) return null;
      final atLogin = state.matchedLocation == '/login';
      if (!s && !atLogin) return '/login';
      if (s && atLogin) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(
        path: '/player',
        parentNavigatorKey: _rootKey,
        pageBuilder: (_, _) => CustomTransitionPage(
          child: const PlayerScreen(),
          transitionsBuilder: (_, anim, _, child) => SlideTransition(
            position: Tween(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      ),
      GoRoute(path: '/queue', parentNavigatorKey: _rootKey, builder: (_, _) => const QueueScreen()),
      // the year (or month) in review: a full-screen story
      GoRoute(
        path: '/review',
        parentNavigatorKey: _rootKey,
        builder: (_, s) => ReviewScreen(
          period: s.uri.queryParameters['period'] == 'month' ? 'month' : 'year',
          offset: int.tryParse(s.uri.queryParameters['offset'] ?? '') ?? 0,
        ),
      ),
      ShellRoute(
        builder: (ctx, state, child) => isDesktop
            ? DesktopShell(location: state.uri.toString(), banner: const _ServerTrouble(), child: child)
            : _Shell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (_, _) => const NoTransitionPage(child: HomeScreen()),
          ),
          GoRoute(
            path: '/discover',
            pageBuilder: (_, _) => const NoTransitionPage(child: DiscoverScreen()),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (_, s) {
              final tab = int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0;
              // the desktop's sidebar opens a tab directly: a new tab, a fresh screen
              return NoTransitionPage(
                key: isDesktop ? ValueKey('library-$tab') : null,
                child: LibraryScreen(key: isDesktop ? ValueKey('library-$tab') : null, initialTab: tab),
              );
            },
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (_, s) {
              final q = s.uri.queryParameters['q'] ?? '';
              return NoTransitionPage(key: ValueKey('search-$q'), child: SearchScreen(key: ValueKey('search-$q'), initialQuery: q));
            },
          ),
          GoRoute(
            path: '/album/:id',
            builder: (_, s) => AlbumScreen(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/artist/:id',
            builder: (_, s) => ArtistScreen(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/playlist/:id',
            builder: (_, s) => PlaylistScreen(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/genre/:name',
            builder: (_, s) => GenreScreen(name: s.pathParameters['name']!),
          ),
          GoRoute(
            path: '/albums/:type',
            builder: (_, s) =>
                AlbumListScreen(type: s.pathParameters['type']!, title: s.uri.queryParameters['title'] ?? 'Albums'),
          ),
          GoRoute(path: '/folders', builder: (_, _) => const FoldersScreen()),
          GoRoute(path: '/radio', builder: (_, _) => const RadioScreen()),
          GoRoute(path: '/liked', builder: (_, _) => const LikedSongsScreen()),
          GoRoute(
            path: '/following',
            builder: (_, s) => FollowingScreen(initialTab: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0),
          ),
          GoRoute(path: '/stats', builder: (_, _) => const StatsScreen()),
          GoRoute(path: '/podcasts/add', builder: (_, _) => const AddPodcastScreen()),
          GoRoute(
            path: '/podcast/:id',
            builder: (_, s) => PodcastScreen(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/podcaster',
            builder: (_, s) =>
                PodcasterScreen(name: s.uri.queryParameters['name'] ?? '', showId: s.uri.queryParameters['show'] ?? ''),
          ),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
          GoRoute(path: '/appearance', builder: (_, _) => const AppearanceScreen()),
          GoRoute(path: '/equalizer', builder: (_, _) => const EqualizerScreen()),
          GoRoute(path: '/downloads', builder: (_, _) => const DownloadsScreen()),
        ],
      ),
    ],
  );
});

/// A plain-words strip above the player when the server answers but can't play music.
class _ServerTrouble extends StatelessWidget {
  const _ServerTrouble();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: serverTrouble,
    builder: (ctx, msg, _) {
      if (msg == null) return const SizedBox.shrink();
      final cs = Theme.of(ctx).colorScheme;
      return Material(
        color: cs.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          child: Row(
            children: [
              Icon(Icons.report_problem_rounded, size: 20, color: cs.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(child: Text(msg, style: TextStyle(color: cs.onErrorContainer))),
              IconButton(
                tooltip: 'Hide',
                icon: Icon(Icons.close_rounded, color: cs.onErrorContainer),
                onPressed: () => serverTrouble.value = null,
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _Shell extends ConsumerWidget {
  const _Shell({required this.location, required this.child});
  final String location;
  final Widget child;

  static String _lastTab = 'home';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final tabs = [for (final k in s.navTabs) _destinations[k]!];
    final here = Settings.defaultNavTabs.where((k) => location.startsWith(_destinations[k]!.path)).firstOrNull;
    if (here != null) _lastTab = here; // detail pages keep the tab they were opened from
    final selected = s.navTabs.indexOf(_lastTab).clamp(0, tabs.length - 1);
    void go(int i) => context.go(tabs[i].path);
    // tablets and landscape: the tabs move to a rail on the side, pages get the width
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final tall = MediaQuery.sizeOf(context).height >= 560;
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: selected,
              // a phone turned sideways is short: no logo, and only the open tab's name
              labelType: switch (s.navLabels) {
                NavLabels.never => NavigationRailLabelType.none,
                NavLabels.always when tall => NavigationRailLabelType.all,
                _ => NavigationRailLabelType.selected,
              },
              groupAlignment: -0.8,
              leading: tall
                  ? const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: EncoreLogo(size: 36))
                  : null,
              onDestinationSelected: go,
              destinations: [
                for (final d in tabs)
                  NavigationRailDestination(icon: d.icon, selectedIcon: d.selectedIcon, label: Text(d.label)),
              ],
            ),
            Expanded(child: child),
          ],
        ),
        bottomNavigationBar: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [_ServerTrouble(), MiniPlayer(), SizedBox(height: 8)],
        ),
      );
    }
    return Scaffold(
      body: child,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _ServerTrouble(),
          const MiniPlayer(),
          NavigationBar(
            selectedIndex: selected,
            height: s.navLabels == NavLabels.never ? 56 : 64,
            labelBehavior: switch (s.navLabels) {
              NavLabels.always => NavigationDestinationLabelBehavior.alwaysShow,
              NavLabels.selected => NavigationDestinationLabelBehavior.onlyShowSelected,
              NavLabels.never => NavigationDestinationLabelBehavior.alwaysHide,
            },
            onDestinationSelected: go,
            destinations: [
              for (final d in tabs) NavigationDestination(icon: d.icon, selectedIcon: d.selectedIcon, label: d.label),
            ],
          ),
        ],
      ),
    );
  }

  /// Every tab there can be, by the name stored in Settings.navTabs.
  static const _destinations = navDestinations;
}

class EncoreApp extends ConsumerStatefulWidget {
  const EncoreApp({super.key});
  @override
  ConsumerState<EncoreApp> createState() => _EncoreAppState();
}

class _EncoreAppState extends ConsumerState<EncoreApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startEpisodeAlerts();
    // your other devices (remote control, moving playback) and small things kept in step with them
    ref.listenManual(devicesProvider, (_, _) {});
    ref.listenManual(syncServiceProvider, (_, _) {});
    // when the network comes back: send plays made offline
    ref.listenManual(offlineProvider, (prev, next) {
      if (prev == true && next == false) {
        audioHandler.flushOfflineScrobbles();
        ref.read(downloadsProvider.notifier).resume(); // downloads that stopped while the server was away carry on
      }
    });
    // keep downloaded collections up to date (new songs in playlists, newly hearted songs)
    Future.delayed(const Duration(seconds: 20), () async {
      await ref.read(downloadsProvider.notifier).refreshPins();
      await ref.read(downloadsProvider.notifier).cleanPlayedEpisodes();
    });
    // keep the phone's copy of the library fresh (for offline browsing): at most every 12 hours
    Future.delayed(const Duration(seconds: 45), _syncIfStale);
    // a newer Encore on GitHub? (at most twice a day; Settings can turn this off)
    Future.delayed(const Duration(seconds: 8), _offerUpdate);
  }

  Future<void> _offerUpdate() async {
    final u = await checkForUpdateQuietly(prefs);
    final ctx = _rootKey.currentContext;
    if (u != null && ctx != null && ctx.mounted) await showUpdateDialog(ctx, u);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(serverReachableProvider.notifier).check();
      ref.read(syncServiceProvider.notifier).syncNow();
      _checkEpisodes();
      _syncIfStale();
      ref.read(usbLinkProvider.notifier).check(); // plugged into the server's computer meanwhile?
      ref.read(localLinkProvider.notifier).check(); // or home, on the server's network?
      ref.read(downloadsProvider.notifier).resume(); // carry on from where they stopped
    }
  }

  Future<void> _syncIfStale() async {
    if (!mounted || !ref.read(repoProvider).online || ref.read(syncProvider).running) return;
    final last = await ref.read(dbProvider).lastSync();
    if (last == null || DateTime.now().difference(last) > const Duration(hours: 12)) {
      await ref.read(syncProvider.notifier).sync();
    }
  }

  // ── New podcast episode notifications ──
  Future<void> _startEpisodeAlerts() async {
    await initNotifications(onTap: _openFromNotification);
    final launch = isDesktop ? null : await notifications.getNotificationAppLaunchDetails(); // Android only
    final payload = launch?.notificationResponse?.payload;
    if (launch?.didNotificationLaunchApp == true && payload != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openFromNotification(payload));
    }
    await startEpisodeChecks();
    _checkEpisodes();
  }

  Future<void> _checkEpisodes() async {
    if (!ref.read(repoProvider).online) return;
    final n = await checkNewEpisodes(p: prefs);
    announceYearReview(p: prefs);
    ref.read(releasesProvider.notifier).refresh(); // once a day at most; it skips artists checked lately
    final c = ref.read(clientProvider);
    if (c != null) await warmPodcastCache(c); // so podcasts still show when the server is away
    if (n > 0) {
      ref.invalidate(podcastsProvider);
      ref.invalidate(newestEpisodesProvider);
    }
    // the first time someone follows podcasts, ask Android for permission to notify
    if (prefs.getStringList('podcastSeen')?.isNotEmpty == true) await askNotificationPermission(prefs);
  }

  void _openFromNotification(String payload) {
    final router = ref.read(routerProvider);
    if (payload.startsWith('podcast:')) {
      router.push('/podcast/${payload.substring(8)}');
    } else if (payload == 'podcasts') {
      router.go('/library?tab=1');
    } else if (payload == 'releases') {
      router.push('/following?tab=1');
    } else if (payload == 'review') {
      router.push('/review');
    }
  }

  /// Minimal dark look: near-black surfaces tinted by the accent, Inter, soft rounded shapes, no borders.
  /// Settings → Appearance changes the black, contrast, typeface, roundness and density.
  static ThemeData theme(ColorScheme scheme, Settings s) {
    final look = AppLook.from(s);
    double r(double v) => look.r(v);
    final base = s.pureBlack
        ? Colors.black
        : Color.alphaBlend(scheme.primary.withValues(alpha: 0.03), const Color(0xFF0E0F13));
    // high contrast: surfaces step apart more clearly and secondary text is nearly white
    final step = s.highContrast ? 1.8 : 1.0;
    final cs = scheme.copyWith(
      surface: base,
      surfaceContainerLowest: base,
      surfaceContainerLow: Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.03 * step), base),
      surfaceContainer: Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.05 * step), base),
      surfaceContainerHigh: Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.08 * step), base),
      surfaceContainerHighest: Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.11 * step), base),
      onSurfaceVariant: s.highContrast
          ? Color.lerp(scheme.onSurfaceVariant, scheme.onSurface, 0.6)
          : scheme.onSurfaceVariant,
      outline: s.highContrast ? Color.lerp(scheme.outline, scheme.onSurface, 0.5) : scheme.outline,
      outlineVariant: s.highContrast ? Color.lerp(scheme.outlineVariant, scheme.onSurface, 0.35) : scheme.outlineVariant,
    );
    final font = s.fontFamily == 'system' ? null : 'Inter';
    final text = Typography.material2021(platform: TargetPlatform.android).white
        .apply(fontFamily: font, bodyColor: cs.onSurface, displayColor: cs.onSurface);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(16)));
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: cs,
      fontFamily: font,
      visualDensity: s.compact ? VisualDensity.compact : VisualDensity.standard,
      extensions: [look],
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      scaffoldBackgroundColor: cs.surface,
      // desktop: a clear gray under the mouse on anything clickable (rows, sidebar, buttons)
      hoverColor: isDesktop ? cs.onSurface.withValues(alpha: 0.09) : null,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: cs.primary.withValues(alpha: 0.16),
        elevation: 0,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? cs.primary : cs.onSurfaceVariant),
        ),
        labelTextStyle: WidgetStatePropertyAll(text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
      ),
      cardTheme: CardThemeData(color: cs.surfaceContainerLow, elevation: 0, shape: shape, margin: EdgeInsets.zero),
      listTileTheme: ListTileThemeData(shape: shape, iconColor: cs.onSurfaceVariant, dense: s.compact),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: cs.surfaceContainerHigh,
        labelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
      tabBarTheme: TabBarThemeData(
        dividerHeight: 0,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(color: cs.primary.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(r(20))),
        labelColor: cs.primary,
        unselectedLabelColor: cs.onSurfaceVariant,
        labelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        labelPadding: const EdgeInsets.symmetric(horizontal: 18),
        splashBorderRadius: BorderRadius.circular(r(20)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cs.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(r(28)))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cs.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(28))),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cs.surfaceContainerHigh,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(r(14)), borderSide: BorderSide.none),
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(cs.surfaceContainerHigh),
        elevation: const WidgetStatePropertyAll(0),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: cs.inverseSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r(12))),
      ),
      sliderTheme: const SliderThemeData(year2023: false),
      progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: false),
      dividerTheme: DividerThemeData(color: cs.onSurface.withValues(alpha: 0.06)),
      // reduce animations: pages appear without sliding
      pageTransitionsTheme: s.reduceMotion
          ? const PageTransitionsTheme(builders: {
              TargetPlatform.android: _NoTransition(),
              TargetPlatform.linux: _NoTransition(),
              TargetPlatform.windows: _NoTransition(),
              TargetPlatform.macOS: _NoTransition(),
            })
          : const PageTransitionsTheme(builders: {TargetPlatform.android: PredictiveBackPageTransitionsBuilder()}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);
    final song = ref.watch(currentSongProvider);
    final art = s.themeSource == ThemeSource.albumArt ? ref.watch(artSchemeProvider(song?.coverArt ?? '')).value : null;
    return DynamicColorBuilder(
      builder: (light, dark) {
        final seeded = ColorScheme.fromSeed(seedColor: Color(s.accentColor), brightness: Brightness.dark);
        final scheme = switch (s.themeSource) {
          ThemeSource.fixed => seeded,
          ThemeSource.albumArt => art ?? dark?.harmonized() ?? seeded,
          ThemeSource.wallpaper => dark?.harmonized() ?? seeded,
        };
        return MaterialApp.router(
          title: 'Encore',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          theme: theme(scheme, s),
          darkTheme: theme(scheme, s),
          routerConfig: router,
          scaffoldMessengerKey: messengerKey,
          // the album-art colours change at once with Reduce animations (or the phone's own switch)
          themeAnimationDuration: s.reduceMotion ||
                  WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations
              ? Duration.zero
              : kThemeAnimationDuration,
          // Appearance's text size goes on top of the phone's own
          // and Reduce animations turns on Flutter's own "no animations" (the phone's switch sets it too), which
          // the app's fades and scrolls follow (see motion() in widgets.dart)
          builder: (ctx, child) {
            final mq = MediaQuery.of(ctx);
            if (s.textScale == 1.0 && !s.reduceMotion) return child!;
            return MediaQuery(
              data: mq.copyWith(
                textScaler: s.textScale == 1.0 ? mq.textScaler : _TimesScaler(mq.textScaler, s.textScale),
                disableAnimations: mq.disableAnimations || s.reduceMotion,
              ),
              child: child!,
            );
          },
        );
      },
    );
  }
}

/// Reduce animations: a new page just appears.
class _NoTransition extends PageTransitionsBuilder {
  const _NoTransition();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      child;
}

/// The phone's text scaling (which Android makes gentler for big text), then Appearance's text size on top.
class _TimesScaler extends TextScaler {
  const _TimesScaler(this.base, this.factor);
  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) => other is _TimesScaler && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}
