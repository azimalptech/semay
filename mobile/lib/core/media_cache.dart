import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Shared disk cache for locally-cached reel/story video files.
/// flutter_cache_manager's DefaultCacheManager expires entries after a 30-day
/// stale period and caps at 200 objects — fine for arbitrary web content, but
/// not what we actually want for a media-heavy feed: like Instagram's local
/// device cache, a downloaded reel/story should stick around until storage
/// pressure actually forces it out, not get silently re-downloaded a month
/// later just because a timer expired. A long stale period + a much higher
/// object cap approximates that "persist indefinitely" behavior — flutter_
/// cache_manager has no direct total-disk-size limit, so the object count is
/// the practical lever here.
class MediaCache {
  MediaCache._();

  static final instance = CacheManager(
    Config(
      'semayMediaCache',
      stalePeriod: const Duration(days: 365),
      maxNrOfCacheObjects: 1000,
    ),
  );
}
