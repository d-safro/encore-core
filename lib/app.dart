import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/settings.dart';
import 'data/account.dart';
import 'data/library.dart';
import 'playback/handler.dart';
import 'ui/screens/browse.dart';
import 'ui/screens/discover.dart';
import 'ui/screens/home.dart';
import 'ui/screens/library.dart';
import 'ui/screens/login.dart';
import 'ui/screens/player.dart';
import 'ui/screens/search.dart';
import 'ui/screens/settings.dart';
import 'ui/state.dart';
import 'ui/widgets.dart';

final _rootKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  final signedIn = ValueNotifier<bool?>(null);
  ref.listen(accountProvider, (_, next) => signedIn.value = next.isLoading ? null : next.value != null,
      fireImmediately: true);
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
            position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      ),
      GoRoute(path: '/queue', parentNavigatorKey: _rootKey, builder: (_, _) => const QueueScreen()),
      ShellRoute(
        builder: (ctx, state, child) => _Shell(location: state.uri.path, child: child),
        routes: [
          GoRoute(path: '/home', pageBuilder: (_, _) => const NoTransitionPage(child: HomeScreen())),
          GoRoute(path: '/discover', pageBuilder: (_, _) => const NoTransitionPage(child: DiscoverScreen())),
          GoRoute(
            path: '/library',
            pageBuilder: (_, s) => NoTransitionPage(
                child: LibraryScreen(initialTab: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0)),
          ),
          GoRoute(path: '/search', pageBuilder: (_, _) => const NoTransitionPage(child: SearchScreen())),
          GoRoute(path: '/album/:id', builder: (_, s) => AlbumScreen(id: s.pathParameters['id']!)),
          GoRoute(path: '/artist/:id', builder: (_, s) => ArtistScreen(id: s.pathParameters['id']!)),
          GoRoute(path: '/playlist/:id', builder: (_, s) => PlaylistScreen(id: s.pathParameters['id']!)),
          GoRoute(path: '/genre/:name', builder: (_, s) => GenreScreen(name: s.pathParameters['name']!)),
          GoRoute(
              path: '/albums/:type',
              builder: (_, s) =>
                  AlbumListScreen(type: s.pathParameters['type']!, title: s.uri.queryParameters['title'] ?? 'Albums')),
          GoRoute(path: '/folders', builder: (_, _) => const FoldersScreen()),
          GoRoute(path: '/radio', builder: (_, _) => const RadioScreen()),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
          GoRoute(path: '/equalizer', builder: (_, _) => const EqualizerScreen()),
          GoRoute(path: '/downloads', builder: (_, _) => const DownloadsScreen()),
        ],
      ),
    ],
  );
});

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
    return Scaffold(
      body: child,
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        const MiniPlayer(),
        NavigationBar(
          selectedIndex: _lastTab,
          onDestinationSelected: (i) => context.go(_tabs[i]),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(
                icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome), label: 'Discover'),
            NavigationDestination(
                icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Library'),
            NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          ],
        ),
      ]),
    );
  }
}

class EncoreApp extends ConsumerStatefulWidget {
  const EncoreApp({super.key});
  @override
  ConsumerState<EncoreApp> createState() => _EncoreAppState();
}

class _EncoreAppState extends ConsumerState<EncoreApp> {
  @override
  void initState() {
    super.initState();
    // when the network comes back: send plays made offline
    ref.listenManual(offlineProvider, (prev, next) {
      if (prev == true && next == false) audioHandler.flushOfflineScrobbles();
    });
  }

  ThemeData _theme(ColorScheme scheme, bool pureBlack) {
    final cs = pureBlack ? scheme.copyWith(surface: Colors.black, surfaceContainerLowest: Colors.black) : scheme;
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      navigationBarTheme: NavigationBarThemeData(backgroundColor: pureBlack ? Colors.black : cs.surfaceContainer),
      sliderTheme: const SliderThemeData(year2023: false),
      progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: false),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final router = ref.watch(routerProvider);
    final song = ref.watch(currentSongProvider);
    final art = s.themeSource == ThemeSource.albumArt ? ref.watch(artSchemeProvider(song?.coverArt ?? '')).value : null;
    return DynamicColorBuilder(builder: (light, dark) {
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
      );
    });
  }
}
