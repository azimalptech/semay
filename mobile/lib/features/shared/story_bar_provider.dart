import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../services/auth_service.dart';

class StoryRingInfo {
  StoryRingInfo({
    required this.storeId,
    required this.storeName,
    required this.avatarUrl,
    required this.hasStories,
    required this.seen,
    required this.isOwn,
  });

  final String storeId;
  final String storeName;
  final String avatarUrl;

  /// False only for an admin's own ring when their store has no active story
  /// (the ring still renders, as the "+" add-story entry point).
  final bool hasStories;

  /// Watched to the end since the store's latest story was posted.
  final bool seen;

  /// The viewer administers this store — ring is pinned first and carries
  /// the "+" badge.
  final bool isOwn;
}

/// Homepage story bar rows — now a single `GET /stories/rings` call that does
/// the own-first/unseen/newest ordering and seen computation server-side
/// (replaces the old 3-listener client stitch; see stories/service.ts
/// getStoryRings). Watches the session so it refetches after login/logout.
final storyBarProvider = FutureProvider<List<StoryRingInfo>>((ref) async {
  // Depend on auth so it re-runs when the user changes (and so it doesn't
  // fire before there's a token to authenticate the request).
  final session = await ref.watch(authStateChangesProvider.future);
  if (session == null) return const [];

  final json = await ref.watch(apiClientProvider).get('/stories/rings');
  final rings = (json['rings'] as List<dynamic>? ?? const []);
  return rings.map((r) {
    final m = r as Map<String, dynamic>;
    return StoryRingInfo(
      storeId: m['storeId'] as String,
      storeName: m['storeName'] as String? ?? '',
      avatarUrl: m['avatarUrl'] as String? ?? '',
      hasStories: m['hasStories'] as bool? ?? false,
      seen: m['seen'] as bool? ?? false,
      isOwn: m['isOwn'] as bool? ?? false,
    );
  }).toList();
});
