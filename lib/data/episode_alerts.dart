import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'models.dart';
import 'subsonic.dart';

/// "New episode" notifications for the podcasts you follow. Checked about every hour in the background
/// (Android WorkManager, only with a network) and whenever the app comes to the front.
final notifications = FlutterLocalNotificationsPlugin();
const _channel = AndroidNotificationDetails(
  'podcast_episodes',
  'New podcast episodes',
  channelDescription: 'When a podcast you follow has a new episode',
  importance: Importance.defaultImportance,
  icon: 'drawable/ic_stat_encore',
);

Future<void> initNotifications({void Function(String payload)? onTap}) async {
  await notifications.initialize(
    settings: const InitializationSettings(android: AndroidInitializationSettings('drawable/ic_stat_encore')),
    onDidReceiveNotificationResponse: (r) {
      if (r.payload != null) onTap?.call(r.payload!);
    },
  );
}

/// Ask Android 13+ for permission to show notifications (once).
Future<void> askNotificationPermission(SharedPreferences p) async {
  if (p.getBool('askedNotifications') == true) return;
  await p.setBool('askedNotifications', true);
  await notifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

bool alertsOn(SharedPreferences p) => p.getBool('podcastAlerts') ?? true;

/// Looks for episodes published since the last check and shows a notification for each (a summary when
/// there are many). The first check only remembers what's there, so following a show doesn't flood you.
Future<int> checkNewEpisodes({SharedPreferences? p, bool notify = true}) async {
  p ??= await SharedPreferences.getInstance();
  await p.reload(); // the background check and the app keep separate copies: read what the other one saw
  const storage = FlutterSecureStorage();
  final server = await storage.read(key: 'server');
  final user = await storage.read(key: 'user');
  final pass = await storage.read(key: 'pass');
  if (server == null || user == null || pass == null) return 0;
  final c = SubsonicClient(Credentials(server, user, pass));
  try {
    final eps = await c.newestEpisodes(count: 40);
    final seen = p.getStringList('podcastSeen');
    final ids = eps.map((e) => e.id).toList();
    if (seen == null) {
      await p.setStringList('podcastSeen', ids);
      return 0;
    }
    final week = DateTime.now().subtract(const Duration(days: 7));
    final fresh = eps
        .where((e) => !seen.contains(e.id) && !e.played && (e.published == null || e.published!.isAfter(week)))
        .toList();
    await p.setStringList('podcastSeen', {...ids, ...seen}.take(600).toList());
    if (fresh.isEmpty || !notify || !alertsOn(p)) return fresh.length;
    if (fresh.length <= 3) {
      for (final e in fresh) {
        await _show(e.id.hashCode & 0x7fffffff, e.show, e.title, 'podcast:${e.channelId}');
      }
    } else {
      final shows = fresh.map((e) => e.show).toSet().join(', ');
      await _show(1, '${fresh.length} new podcast episodes', shows, 'podcasts');
    }
    return fresh.length;
  } catch (_) {
    return 0; // offline / server away: try again next time
  } finally {
    c.close();
  }
}

Future<void> _show(int id, String title, String body, String payload) => notifications.show(
  id: id,
  title: title,
  body: body,
  notificationDetails: const NotificationDetails(android: _channel),
  payload: payload,
);

// ── Background check ──
@pragma('vm:entry-point')
void episodeCheckDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await initNotifications();
      await checkNewEpisodes();
    } catch (_) {}
    return true;
  });
}

Future<void> startEpisodeChecks() async {
  try {
    await Workmanager().initialize(episodeCheckDispatcher);
    await Workmanager().registerPeriodicTask(
      'encore-new-episodes',
      'new-episodes',
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (_) {}
}

/// For the app's own screens.
bool isNewEpisode(PodcastEpisode e) =>
    !e.played && e.published != null && DateTime.now().difference(e.published!) < const Duration(days: 7);
