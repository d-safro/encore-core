import 'package:crypto/crypto.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Navidrome answers "no cover" with this exact image (same bytes at every size); treat it as missing.
const noCoverLength = 69228;
const noCoverMd5 = '83d193cefca2810f217cffd533241508';

/// Not a real picture: Navidrome's "no cover" record, an error message, or next to nothing.
bool isNoCover(List<int> bytes) =>
    bytes.length < 64 ||
    bytes.first == 0x7B || // '{': an error message, not an image
    (bytes.length == noCoverLength && md5.convert(bytes).toString() == noCoverMd5);

/// The first real picture from [tries], in order (one that fails or isn't a real picture: the next).
Future<List<int>?> firstRealPicture(Iterable<Future<List<int>?> Function()> tries) async {
  for (final get in tries) {
    try {
      final bytes = await get();
      if (bytes != null && !isNoCover(bytes)) return bytes;
    } catch (_) {
      // try the next
    }
  }
  return null;
}

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
