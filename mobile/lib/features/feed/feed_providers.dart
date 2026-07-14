import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/firestore_service.dart';

typedef PostDoc = QueryDocumentSnapshot<Map<String, dynamic>>;

const feedPageSize = 10;

class FeedNotifier extends AsyncNotifier<List<PostDoc>> {
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool hasMore = true;

  Query<Map<String, dynamic>> get _baseQuery => ref
      .read(firestoreProvider)
      .collection('posts')
      .withConverter<Map<String, dynamic>>(
        fromFirestore: (snap, _) => snap.data()!,
        toFirestore: (data, _) => data,
      )
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

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
  }
}

final feedNotifierProvider = AsyncNotifierProvider<FeedNotifier, List<PostDoc>>(FeedNotifier.new);
