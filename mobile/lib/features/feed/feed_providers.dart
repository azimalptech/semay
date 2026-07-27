import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';
import '../../core/read_cache.dart';

/// A post as the new REST API returns it — a flat JSON map with `id` inside,
/// wrapped so screens keep calling `doc.id` / `doc.data()` unchanged (see
/// JsonDoc). Replaces the old `QueryDocumentSnapshot<Map<String,dynamic>>`.
typedef PostDoc = JsonDoc;

const feedPageSize = 10;

List<PostDoc> postsFromResponse(Map<String, dynamic> json) {
  final list = (json['posts'] as List<dynamic>? ?? const []);
  return list
      .map((e) => PostDoc(normalizePost(e as Map<String, dynamic>)))
      .toList();
}

// Whether a loadMore() page fetch is currently in flight — feed_view.dart
// watches this to show a small spinner at the bottom of the list while the
// next page loads.
class FeedLoadingMoreNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  set loading(bool value) => state = value;
}

final feedLoadingMoreProvider = NotifierProvider<FeedLoadingMoreNotifier, bool>(
  FeedLoadingMoreNotifier.new,
);

class FeedNotifier extends AsyncNotifier<List<PostDoc>> {
  int _offset = 0;
  bool hasMore = true;
  bool _isLoadingMore = false;

  static const _cacheKey = 'feed:page0';

  @override
  Future<List<PostDoc>> build() async {
    _offset = 0;
    hasMore = true;

    // Read-side cache instant-paint (Phase 9b) — emit the last-seen first page
    // immediately so the feed isn't a blank spinner on a fresh launch, then let
    // the network fetch below supersede it. Replaces Firestore's Source.cache.
    final cache = ref.read(readCacheProvider);
    final cached = await cache.readList(_cacheKey);
    if (cached != null && cached.isNotEmpty) {
      state = AsyncData(cached.map((e) => PostDoc(normalizePost(e))).toList());
    }

    final json = await ref
        .read(apiClientProvider)
        .get('/feed', query: {'limit': feedPageSize, 'offset': 0});
    final rawPosts = (json['posts'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    await cache.writeList(_cacheKey, rawPosts);
    final posts = postsFromResponse(json);
    _offset = posts.length;
    hasMore = posts.length == feedPageSize;
    return posts;
  }

  Future<void> loadMore() async {
    if (!hasMore || _isLoadingMore) return;
    _isLoadingMore = true;
    ref.read(feedLoadingMoreProvider.notifier).loading = true;
    try {
      final current = state.value ?? [];
      final json = await ref
          .read(apiClientProvider)
          .get('/feed', query: {'limit': feedPageSize, 'offset': _offset});
      final page = postsFromResponse(json);
      _offset += page.length;
      hasMore = page.length == feedPageSize;
      state = AsyncData([...current, ...page]);
    } finally {
      _isLoadingMore = false;
      ref.read(feedLoadingMoreProvider.notifier).loading = false;
    }
  }

  Future<void> refresh() async {
    // invalidateSelf() preserves the previous list in state.value while this
    // resolves, so screens checking hasValue keep showing existing posts.
    ref.invalidateSelf();
    await future;
  }
}

final feedNotifierProvider = AsyncNotifierProvider<FeedNotifier, List<PostDoc>>(
  FeedNotifier.new,
);
