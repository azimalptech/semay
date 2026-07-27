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
