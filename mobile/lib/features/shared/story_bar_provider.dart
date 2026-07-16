import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../../services/firestore_service.dart';

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

/// storeId -> latest active story createdAt.
final _activeStoriesProvider = StreamProvider<Map<String, Timestamp>>((ref) {
  return ref
      .watch(firestoreProvider)
      .collection('stories')
      .where('expiresAt', isGreaterThan: Timestamp.now())
      .snapshots()
      .map((snap) {
    final latest = <String, Timestamp>{};
    for (final doc in snap.docs) {
      final storeId = doc.data()['storeId'] as String;
      final createdAt = doc.data()['createdAt'] as Timestamp? ?? Timestamp.now();
      final current = latest[storeId];
      if (current == null || createdAt.compareTo(current) > 0) latest[storeId] = createdAt;
    }
    return latest;
  });
});

/// storeId -> when the signed-in user last watched that store's stories
/// through to the end (`users/{uid}/storySeen/{storeId}`).
final _storySeenProvider = StreamProvider<Map<String, Timestamp>>((ref) {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return Stream.value(const {});

  return ref
      .watch(firestoreProvider)
      .collection('users')
      .doc(user.uid)
      .collection('storySeen')
      .snapshots()
      .map((snap) => {
            for (final doc in snap.docs)
              if (doc.data()['seenAt'] is Timestamp) doc.id: doc.data()['seenAt'] as Timestamp,
          });
});

/// Homepage story bar rows: admin's own store pinned first (always shown, as
/// the add-story entry point), then unseen rings newest-first, then seen ones.
final storyBarProvider = FutureProvider<List<StoryRingInfo>>((ref) async {
  final firestore = ref.watch(firestoreProvider);
  final active = await ref.watch(_activeStoriesProvider.future);
  final seenMap = ref.watch(_storySeenProvider).value ?? const {};
  final ownStoreIds = ref.watch(storeIdsProvider).value ?? const [];

  final storeIds = <String>{...active.keys, ...ownStoreIds};
  if (storeIds.isEmpty) return const [];

  final infos = <StoryRingInfo>[];
  for (final storeId in storeIds) {
    final storeSnap = await firestore.collection('stores').doc(storeId).get();
    final data = storeSnap.data();
    if (data == null) continue;

    final latestAt = active[storeId];
    final seenAt = seenMap[storeId];
    infos.add(StoryRingInfo(
      storeId: storeId,
      storeName: data['name'] as String? ?? '',
      avatarUrl: data['avatarUrl'] as String? ?? '',
      hasStories: latestAt != null,
      seen: latestAt != null && seenAt != null && seenAt.compareTo(latestAt) >= 0,
      isOwn: ownStoreIds.contains(storeId),
    ));
  }

  int latestMillis(StoryRingInfo r) => active[r.storeId]?.millisecondsSinceEpoch ?? 0;
  infos.sort((a, b) {
    if (a.isOwn != b.isOwn) return a.isOwn ? -1 : 1;
    if (a.seen != b.seen) return a.seen ? 1 : -1;
    return latestMillis(b).compareTo(latestMillis(a));
  });
  return infos;
});
