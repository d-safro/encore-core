import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/settings.dart';
import 'data/episode_alerts.dart';
import 'data/account.dart';
import 'data/library.dart';
import 'playback/handler.dart';
import 'ui/screens/browse.dart';
import 'ui/screens/discover.dart';
import 'ui/screens/home.dart';
import 'ui/screens/library.dart';
import 'ui/screens/podcasts.dart';
import 'ui/screens/login.dart';
import 'ui/screens/player.dart';
import 'ui/screens/search.dart';
import 'ui/screens/settings.dart';
import 'data/updates.dart';
import 'ui/state.dart';
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
    initialLocation: '/home',
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
      ShellRoute(
        builder: (ctx, state, child) => _Shell(location: state.uri.path, child: child),
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
            pageBuilder: (_, s) => NoTransitionPage(
              child: LibraryScreen(initialTab: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0),
            ),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (_, _) => const NoTransitionPage(child: SearchScreen()),
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
          GoRoute(path: '/stats', builder: (_, _) => const StatsScreen()),
          GoRoute(path: '/podcasts/add', builder: (_, _) => const AddPodcastScreen()),
          GoRoute(
            path: '/podcast/:id',
            builder: (_, s) => PodcastScreen(id: s.pathParameters['id']!),
          ),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
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

  static const _tabs = ['/home', '/discover', '/library', '/search'];
  static int _lastTab = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idx = _tabs.indexWhere(location.startsWith);
    if (idx >= 0) _lastTab = idx; // detail pages keep the tab they were opened from
    // tablets and landscape: the tabs move to a rail on the side, pages get the width
    final wide = MediaQuery.sizeOf(context).width >= 700;
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _lastTab,
              labelType: NavigationRailLabelType.all,
              groupAlignment: -0.8,
              leading: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: EncoreLogo(size: 36)),
              onDestinationSelected: (i) => context.go(_tabs[i]),
              destinations: [
                for (final d in _destinations)
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
            selectedIndex: _lastTab,
            height: 64,
            labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
            onDestinationSelected: (i) => context.go(_tabs[i]),
            destinations: [
              for (final d in _destinations)
                NavigationDestination(icon: d.icon, selectedIcon: d.selectedIcon, label: d.label),
            ],
          ),
        ],
      ),
    );
  }

  static const _destinations = [
    (icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
    (icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome), label: 'Discover'),
    (icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music_rounded), label: 'Library'),
    (icon: Icon(Icons.search_rounded), selectedIcon: Icon(Icons.search_rounded), label: 'Search'),
  ];
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
    // when the network comes back: send plays made offline
    ref.listenManual(offlineProvider, (prev, next) {
      if (prev == true && next == false) {
        audioHandler.flushOfflineScrobbles();
        FileDownloader().resumeAll(); // downloads that stopped while the server was away carry on
      }
    });
    // keep downloaded collections up to date (new songs in playlists, newly hearted songs)
    Future.delayed(const Duration(seconds: 20), () => ref.read(downloadsProvider.notifier).refreshPins());
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
      _checkEpisodes();
      _syncIfStale();
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
    final launch = await notifications.getNotificationAppLaunchDetails();
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
    }
  }

  /// Minimal dark look: near-black surfaces tinted by the accent, Inter, soft rounded shapes, no borders.
  ThemeData _theme(ColorScheme scheme, bool pureBlack) {
    final base = pureBlack
        ? Colors.black
        : Color.alphaBlend(scheme.primary.withValues(alpha: 0.03), const Color(0xFF0E0F13));
    final cs = scheme.copyWith(
      surface: base,
      surfaceContainerLowest: base,
      surfaceContainerLow: Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.03), base),
      surfaceContainer: Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.05), base),
      surfaceContainerHigh: Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.08), base),
      surfaceContainerHighest: Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.11), base),
    );
    final text = Typography.material2021(platform: TargetPlatform.android).white
        .apply(fontFamily: 'Inter', bodyColor: cs.onSurface, displayColor: cs.onSurface);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: cs,
      fontFamily: 'Inter',
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      scaffoldBackgroundColor: cs.surface,
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
      listTileTheme: ListTileThemeData(shape: shape, iconColor: cs.onSurfaceVariant),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: cs.surfaceContainerHigh,
        labelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
      tabBarTheme: TabBarThemeData(
        dividerHeight: 0,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(color: cs.primary.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
        labelColor: cs.primary,
        unselectedLabelColor: cs.onSurfaceVariant,
        labelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        labelPadding: const EdgeInsets.symmetric(horizontal: 18),
        splashBorderRadius: BorderRadius.circular(20),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cs.surfaceContainer,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(backgroundColor: cs.surfaceContainer, surfaceTintColor: Colors.transparent),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cs.surfaceContainerHigh,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(cs.surfaceContainerHigh),
        elevation: const WidgetStatePropertyAll(0),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: cs.inverseSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      sliderTheme: const SliderThemeData(year2023: false),
      progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: false),
      dividerTheme: DividerThemeData(color: cs.onSurface.withValues(alpha: 0.06)),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {TargetPlatform.android: PredictiveBackPageTransitionsBuilder()},
      ),
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
          theme: _theme(scheme, s.pureBlack),
          darkTheme: _theme(scheme, s.pureBlack),
          routerConfig: router,
          scaffoldMessengerKey: messengerKey,
        );
      },
    );
  }
}
