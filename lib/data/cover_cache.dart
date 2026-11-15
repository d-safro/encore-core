import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Album covers and artist photos on the phone. Sized for a whole library: Flutter's default keeps 200
/// pictures, so covers were thrown away and fetched again all the time (and only trimmed what wasn't
/// used for a day, so a long browse still piled up hundreds of MB).
final coverCache = CacheManager(
  Config('encoreCovers', stalePeriod: const Duration(days: 180), maxNrOfCacheObjects: 6000),
);

/// Once: empty the old general picture cache that covers used to share (nothing fills it any more
/// except the media notification, which fetches what it needs again).
Future<void> dropOldCoverCache(SharedPreferences p) async {
  if (p.getBool('oldCoverCacheDropped') == true) return;
  try {
    await DefaultCacheManager().emptyCache();
    await p.setBool('oldCoverCacheDropped', true);
  } catch (_) {}
}
