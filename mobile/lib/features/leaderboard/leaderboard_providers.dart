import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/firestore_service.dart';

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
  // showing a placeholder. Each store's own campaign banner, not a shared
  // global one (see docs/02_DATA_MODEL.md's stores/{storeId}.campaignImageUrl).
  final String? campaignImageUrl;
}

/// Shop tabs across the top of the leaderboard — every active store, so the
/// list matches whatever's actually visible to browse/order from elsewhere
/// in the app. Sorted in memory by leaderboardOrder (superadmin-controlled,
/// see docs/02_DATA_MODEL.md) rather than a Firestore orderBy — older stores
/// predate that field, and orderBy would silently drop any doc missing it
/// from the results instead of just sorting it last.
final leaderboardStoresProvider = StreamProvider<List<StoreTab>>((ref) {
  return ref
      .watch(firestoreProvider)
      .collection('stores')
      .where('active', isEqualTo: true)
      .snapshots()
      .map((snap) {
        final tabs = [
          for (final doc in snap.docs)
            StoreTab(
              storeId: doc.id,
              name: doc.data()['name'] as String? ?? '',
              order: doc.data()['leaderboardOrder'] as int? ?? 1 << 30,
              campaignImageUrl: doc.data()['campaignImageUrl'] as String?,
            ),
        ];
        tabs.sort((a, b) {
          final byOrder = a.order.compareTo(b.order);
          return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
        });
        return tabs;
      });
});

final leaderboardEntriesProvider =
    StreamProvider.family<
      List<QueryDocumentSnapshot<Map<String, dynamic>>>,
      String
    >((ref, storeId) {
      return ref
          .watch(firestoreProvider)
          .collection('stores')
          .doc(storeId)
          .collection('leaderboard')
          .orderBy('quantity', descending: true)
          .limit(20)
          .snapshots()
          .map((snap) => snap.docs);
    }, isAutoDispose: true);
