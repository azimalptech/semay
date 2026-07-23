import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/firestore_service.dart';

/// That store's stories, oldest first, filtered to non-expired in memory as a
/// safety net for the up-to-59-minute window before `expireStories` next runs.
final storeStoriesProvider =
    StreamProvider.family<
      List<QueryDocumentSnapshot<Map<String, dynamic>>>,
      String
    >((ref, storeId) {
      return ref
          .watch(firestoreProvider)
          .collection('stories')
          .where('storeId', isEqualTo: storeId)
          .orderBy('createdAt')
          .snapshots()
          .map((snap) {
            final now = Timestamp.now();
            return snap.docs.where((doc) {
              final expiresAt = doc.data()['expiresAt'] as Timestamp?;
              return expiresAt == null || expiresAt.compareTo(now) > 0;
            }).toList();
          });
    }, isAutoDispose: true);
