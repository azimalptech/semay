import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/firestore_service.dart';

class StoryRingInfo {
  StoryRingInfo({required this.storeId, required this.storeName, required this.avatarUrl});

  final String storeId;
  final String storeName;
  final String avatarUrl;
}

/// One ring per store with an active (non-expired) story, for the homepage bar.
final storyBarProvider = StreamProvider<List<StoryRingInfo>>((ref) {
  final firestore = ref.watch(firestoreProvider);

  return firestore
      .collection('stories')
      .where('expiresAt', isGreaterThan: Timestamp.now())
      .snapshots()
      .asyncMap((snap) async {
    final storeIds = <String>{};
    for (final doc in snap.docs) {
      storeIds.add(doc.data()['storeId'] as String);
    }

    final infos = <StoryRingInfo>[];
    for (final storeId in storeIds) {
      final storeSnap = await firestore.collection('stores').doc(storeId).get();
      final data = storeSnap.data();
      infos.add(StoryRingInfo(
        storeId: storeId,
        storeName: data?['name'] as String? ?? '',
        avatarUrl: data?['avatarUrl'] as String? ?? '',
      ));
    }
    return infos;
  });
});
