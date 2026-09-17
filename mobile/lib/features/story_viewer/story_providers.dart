import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';
import '../../core/shell_tab.dart';
import '../feed/feed_providers.dart';
import '../shared/story_bar_provider.dart';

/// That store's active stories, oldest first. The server already filters to
/// non-expired (`expiresAt > now`); the story viewer just needs the ordered
/// list. Uses PostDoc's JsonDoc wrapper so the viewer keeps reading
/// `doc.id` / `doc.data()['mediaUrl']` unchanged.
final storeStoriesProvider = FutureProvider.family<List<PostDoc>, String>((
  ref,
  storeId,
) async {
  final json = await ref.watch(apiClientProvider).get('/stores/$storeId/stories');
  final list = (json['stories'] as List<dynamic>? ?? const []);
  return list.map((e) => PostDoc(e as Map<String, dynamic>)).toList();
}, isAutoDispose: true);

/// Whether a store has an active story right now, and whether the viewer has
/// watched them all — what the store profile's avatar ring draws.
class StoreStoryState {
  const StoreStoryState({required this.hasStories, required this.seen});

  final bool hasStories;
  final bool seen;
}

/// Source of truth for the store profile ring. `hasStories` comes from the
/// exact per-store list ([storeStoriesProvider] — the server already drops
/// expired rows), `seen` from the rings GET the home bar reads, so the two
/// surfaces never disagree; a store missing from the rings list counts as
/// unseen. Expiry has no server event (maintenance.ts reaps with a one-hour
/// grace and publishes nothing), so this schedules its own re-read for the
/// moment the earliest `expiresAt` passes — the ring drops while the screen
/// is open instead of on the next visit — and re-reads on app resume, when
/// the phone may have slept through that moment. autoDispose on purpose: the
/// timer can be up to 24 h out, and a keep-alive provider would leak one per
/// store ever visited.
final storeHasActiveStoriesProvider =
    Provider.family<StoreStoryState, String>((ref, storeId) {
      final now = DateTime.now();
      final storiesAsync = ref.watch(storeStoriesProvider(storeId));
      final stories = storiesAsync.value ?? const <PostDoc>[];
      // Filter client-side as well: while a re-read is in flight the value
      // held is the previous list, and a story that has crossed expiresAt
      // must not light the ring for that round trip (or at all, if the phone
      // is offline and the re-read fails).
      DateTime? earliest;
      var active = 0;
      for (final story in stories) {
        final expiresAt = parseTimestamp(story.data()['expiresAt']);
        if (expiresAt != null && !expiresAt.isAfter(now)) continue;
        active++;
        if (expiresAt != null &&
            (earliest == null || expiresAt.isBefore(earliest))) {
          earliest = expiresAt;
        }
      }
      // BOTH inputs, everywhere: `seen` is server-computed as
      // `seenAt >= latestAt` (stories/service.ts), so a new story makes the
      // cached `seen: true` wrong the instant it lands. Re-reading only the
      // list left the ring MUTED for a story the user has never seen — the
      // "muted when all seen" rule exactly inverted — until something else
      // happened to refresh the rings.
      void refreshBothInputs() {
        ref.invalidate(storeStoriesProvider(storeId));
        ref.invalidate(storyBarProvider);
      }

      if (earliest != null) {
        // One second past the boundary so the server's `expiresAt > now`
        // filter has certainly flipped by the time the re-read lands.
        final timer = Timer(
          earliest.difference(now) + const Duration(seconds: 1),
          refreshBothInputs,
        );
        ref.onDispose(timer.cancel);
      }
      ref.listen(appInForegroundProvider, (wasInForeground, inForeground) {
        if (inForeground && wasInForeground == false) refreshBothInputs();
      });
      final ring = ref
          .watch(storyBarProvider)
          .value
          ?.where((r) => r.storeId == storeId)
          .firstOrNull;
      // While the per-store GET is still in flight there is nothing to count,
      // and answering "no ring" for that round trip made the ring pop in a
      // beat after the header drew. The rings list is keep-alive and normally
      // already holds this store's answer, so start from it and switch to the
      // exact per-store count the moment it lands.
      if (!storiesAsync.hasValue) {
        return StoreStoryState(
          hasStories: ring?.hasStories ?? false,
          seen: ring?.seen ?? false,
        );
      }
      return StoreStoryState(hasStories: active > 0, seen: ring?.seen ?? false);
    }, isAutoDispose: true);
