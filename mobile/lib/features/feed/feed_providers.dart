import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/firestore_service.dart';

typedef PostDoc = QueryDocumentSnapshot<Map<String, dynamic>>;

const feedPageSize = 10;

// Whether a loadMore() page fetch is currently in flight — feed_view.dart
// watches this to show a small spinner at the bottom of the list while the
// next 10 posts load, same as Instagram's own feed. A separate Notifier
// (not a field read off FeedNotifier itself) because reading a field
// directly off an AsyncNotifier's instance doesn't trigger a rebuild when
// that field changes — only reassigning `state` does.
class FeedLoadingMoreNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  set loading(bool value) => state = value;
}

final feedLoadingMoreProvider = NotifierProvider<FeedLoadingMoreNotifier, bool>(
  FeedLoadingMoreNotifier.new,
);

class FeedNotifier extends AsyncNotifier<List<PostDoc>> {
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool hasMore = true;
  bool _isLoadingMore = false;

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

    // Firestore keeps a local disk cache automatically (on by default on
    // mobile) — read it first so the feed paints instantly from whatever
    // was already loaded on a previous visit instead of sitting on a blank
    // spinner every single time while waiting on a network round trip. The
    // real network fetch below still runs and supersedes this once it lands.
    try {
      final cached = await _baseQuery
          .limit(feedPageSize)
          .get(const GetOptions(source: Source.cache));
      if (cached.docs.isNotEmpty) state = AsyncData(cached.docs);
    } catch (_) {
      // No cache yet (e.g. first-ever launch) — the network fetch covers it.
    }

    final snap = await _baseQuery.limit(feedPageSize).get();
    if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
    hasMore = snap.docs.length == feedPageSize;
    return snap.docs;
  }

  Future<void> loadMore() async {
    // The scroll listener fires on every pixel within range of the bottom,
    // so without this guard fast scrolling fires loadMore() many times
    // before the first request even returns — each one reads the same
    // _lastDoc and appends the same page, duplicating posts (and their
    // video controllers, for reels) in the feed.
    if (!hasMore || _lastDoc == null || _isLoadingMore) return;
    _isLoadingMore = true;
    ref.read(feedLoadingMoreProvider.notifier).loading = true;
    try {
      final current = state.value ?? [];
      final snap = await _baseQuery
          .startAfterDocument(_lastDoc!)
          .limit(feedPageSize)
          .get();
      if (snap.docs.isNotEmpty) _lastDoc = snap.docs.last;
      hasMore = snap.docs.length == feedPageSize;
      state = AsyncData([...current, ...snap.docs]);
    } finally {
      _isLoadingMore = false;
      ref.read(feedLoadingMoreProvider.notifier).loading = false;
    }
  }

  Future<void> refresh() async {
    // invalidateSelf() (unlike manually assigning AsyncLoading()) preserves
    // the previous list in state.value while this resolves, via Riverpod's
    // own invalidation machinery — so screens checking hasValue first (not
    // a bare .when()) can keep showing existing posts instead of blanking.
    ref.invalidateSelf();
    await future;
  }
}

final feedNotifierProvider = AsyncNotifierProvider<FeedNotifier, List<PostDoc>>(
  FeedNotifier.new,
);
