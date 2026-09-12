import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';

class StoreTab {
  const StoreTab({
    required this.storeId,
    required this.name,
    required this.order,
    required this.campaignImageUrl,
  });
  final String storeId;
  final String name;
  final int order;
  // null when this store hasn't had a 3x2 banner uploaded from the Super
  // Admin panel — the screen collapses the space entirely rather than
  // showing a placeholder.
  final String? campaignImageUrl;
}

/// Shop tabs across the top of the leaderboard — every active store, sorted by
/// leaderboardOrder (superadmin-controlled). REST + pull-to-refresh; no
/// realtime channel (leaderboard changes are infrequent).
///
/// Kept alive on purpose — the trophy tab is a page of the always-mounted
/// shell pager (router.dart's _SwipeableTabShell), so auto-dispose would never
/// actually fire. [refreshLeaderboard] is what re-reads it; until it existed
/// this list was fetched exactly once per app launch and a store added or
/// deactivated afterwards never showed up.
final leaderboardStoresProvider = FutureProvider<List<StoreTab>>((ref) async {
  final json = await ref.watch(apiClientProvider).get('/stores');
  final stores = (json['stores'] as List<dynamic>? ?? const []);
  final tabs = [
    for (final s in stores)
      StoreTab(
        storeId: (s as Map<String, dynamic>)['id'] as String,
        name: s['name'] as String? ?? '',
        order: s['leaderboardOrder'] as int? ?? 1 << 30,
        campaignImageUrl: s['campaignImageUrl'] as String?,
      ),
  ];
  tabs.sort((a, b) {
    final byOrder = a.order.compareTo(b.order);
    return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
  });
  return tabs;
});

/// A store's top-20 leaderboard entries (by order quantity). Server-computed
/// aggregate (store_leaderboard table); one-shot fetch with pull-to-refresh.
final leaderboardEntriesProvider =
    FutureProvider.family<List<JsonDoc>, String>((ref, storeId) async {
      final json = await ref
          .watch(apiClientProvider)
          .get('/stores/$storeId/leaderboard');
      final entries = (json['entries'] as List<dynamic>? ?? const []);
      return entries.map((e) => JsonDoc(e as Map<String, dynamic>)).toList();
    }, isAutoDispose: true);

/// Pull-to-refresh for the trophy tab: both the shop tabs and the ranking of
/// the store being looked at. Neither has a realtime channel, and the screen
/// is never disposed (shell pager), so this gesture is the only way a new
/// order — or a new store — reaches the screen inside a session.
///
/// Errors are swallowed — a failed pull must not throw out of the indicator —
/// and reported by the returned flag instead: false means at least one of the
/// two reads failed. The screen shows a snackbar for that rather than letting
/// the failure replace a leaderboard that is already on screen (see
/// `skipError` in leaderboard_screen.dart).
///
/// [storeId] is null when no store is selected yet (the tabs themselves failed
/// to load or came back empty) — then this refreshes just the tabs.
Future<bool> refreshLeaderboard(WidgetRef ref, String? storeId) async {
  // Both started before either is awaited, so this is one round trip.
  final stores = ref.refresh(leaderboardStoresProvider.future);
  final entries = storeId == null
      ? null
      : ref.refresh(leaderboardEntriesProvider(storeId).future);
  var ok = true;
  try {
    await stores;
  } catch (_) {
    ok = false;
  }
  try {
    await entries;
  } catch (_) {
    ok = false;
  }
  return ok;
}
