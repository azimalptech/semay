import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/firestore_service.dart';
import '../feed/feed_providers.dart';

final storeDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((ref, storeId) {
  return ref
      .watch(firestoreProvider)
      .collection('stores')
      .doc(storeId)
      .snapshots()
      .map((snap) => snap.data());
});

class StorePostsNotifier extends AsyncNotifier<List<PostDoc>> {
  StorePostsNotifier(this.storeId);

  final String storeId;

  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool hasMore = true;

  Query<Map<String, dynamic>> get _baseQuery => ref
      .read(firestoreProvider)
      .collection('posts')
      .withConverter<Map<String, dynamic>>(
        fromFirestore: (snap, _) => snap.data()!,
        toFirestore: (data, _) => data,
      )
      .where('storeId', isEqualTo: storeId)
      .orderBy('createdAt', descending: true);

  @override
  Future<List<PostDoc>> build() async {
    _lastDoc = null;
    hasMore = true;
    final snap = await _baseQuery.limit(feedPageSize).get();
    if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
    hasMore = snap.docs.length == feedPageSize;
    return snap.docs;
  }

  Future<void> loadMore() async {
    if (!hasMore || _lastDoc == null) return;
    final current = state.value ?? [];
    final snap = await _baseQuery.startAfterDocument(_lastDoc!).limit(feedPageSize).get();
    if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
    hasMore = snap.docs.length == feedPageSize;
    state = AsyncData([...current, ...snap.docs]);
  }
}

final storePostsProvider = AsyncNotifierProvider.family<StorePostsNotifier, List<PostDoc>, String>(
  (storeId) => StorePostsNotifier(storeId),
);

class StoreReelsNotifier extends AsyncNotifier<List<PostDoc>> {
  StoreReelsNotifier(this.storeId);

  final String storeId;

  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool hasMore = true;

  Query<Map<String, dynamic>> get _baseQuery => ref
      .read(firestoreProvider)
      .collection('posts')
      .withConverter<Map<String, dynamic>>(
        fromFirestore: (snap, _) => snap.data()!,
        toFirestore: (data, _) => data,
      )
      .where('storeId', isEqualTo: storeId)
      .where('type', isEqualTo: 'reel')
      .orderBy('createdAt', descending: true);

  @override
  Future<List<PostDoc>> build() async {
    _lastDoc = null;
    hasMore = true;
    final snap = await _baseQuery.limit(feedPageSize).get();
    if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
    hasMore = snap.docs.length == feedPageSize;
    return snap.docs;
  }

  Future<void> loadMore() async {
    if (!hasMore || _lastDoc == null) return;
    final current = state.value ?? [];
    final snap = await _baseQuery.startAfterDocument(_lastDoc!).limit(feedPageSize).get();
    if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
    hasMore = snap.docs.length == feedPageSize;
    state = AsyncData([...current, ...snap.docs]);
  }
}

final storeReelsProvider = AsyncNotifierProvider.family<StoreReelsNotifier, List<PostDoc>, String>(
  (storeId) => StoreReelsNotifier(storeId),
);
