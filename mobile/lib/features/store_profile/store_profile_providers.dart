import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';
import '../../core/read_cache.dart';
import '../../core/realtime_client.dart';
import '../feed/feed_providers.dart';

/// Live store doc — subscribes to the `store:{id}` realtime channel so an edit
/// (rename, new avatar, campaign change) shows on an already-open profile
/// immediately, same as the old Firestore snapshot. autoDispose keeps the WS
/// subscription ref-counted to this provider's listeners (see RealtimeClient).
final storeDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((
  ref,
  storeId,
) async* {
  // Emissions in order of freshness: the cached copy from the last visit (so
  // the chat header/list shows the store's name instantly and offline), the
  // current value over REST (paints without waiting on the WS snapshot
  // frame), then live updates from the WS channel's snapshot/upsert events.
  // Every fresh value is written back for next time.
  final api = ref.watch(apiClientProvider);
  final cache = ref.read(readCacheProvider);
  final cacheKey = 'store:$storeId:doc';
  Map<String, dynamic>? current;
  final cached = await cache.readList(cacheKey);
  if (cached != null && cached.isNotEmpty) {
    current = cached.first;
    yield current;
  }
  try {
    final json = await api.get('/stores/$storeId');
    current = json['store'] as Map<String, dynamic>?;
    yield current;
    if (current != null) await cache.writeList(cacheKey, [current]);
  } catch (_) {
    if (current == null) yield null;
  }
  await for (final event in ref.watch(realtimeClientProvider).subscribe('store:$storeId')) {
    if (event.type == RealtimeEventType.snapshot || event.type == RealtimeEventType.upsert) {
      current = event.data as Map<String, dynamic>?;
      yield current;
      if (current != null) await cache.writeList(cacheKey, [current]);
    }
  }
}, isAutoDispose: true);

/// Paginated store posts (all types) — REST + offset paging, replacing the
/// old Firestore cursor query. No realtime channel: a store's post *list* uses
/// pull-to-refresh, matching the feed (see docs/07_MIGRATION.md Phase 9 scope).
class StorePostsNotifier extends AsyncNotifier<List<PostDoc>> {
  StorePostsNotifier(this.storeId);

  final String storeId;

  int _offset = 0;
  bool hasMore = true;

  Future<List<Map<String, dynamic>>> _fetchRaw(int offset) async {
    final json = await ref.read(apiClientProvider).get(
      '/stores/$storeId/posts',
      query: {'limit': feedPageSize, 'offset': offset},
    );
    return (json['posts'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
  }

  @override
  Future<List<PostDoc>> build() async {
    _offset = 0;
    hasMore = true;

    final cacheKey = 'store:$storeId:posts:page0';
    final cache = ref.read(readCacheProvider);
    final cached = await cache.readList(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      state = AsyncData(cached.map((e) => PostDoc(normalizePost(e))).toList());
    }

    final raw = await _fetchRaw(0);
    await cache.writeList(cacheKey, raw);
    final posts = raw.map((e) => PostDoc(normalizePost(e))).toList();
    _offset = posts.length;
    hasMore = posts.length == feedPageSize;
    return posts;
  }

  Future<void> loadMore() async {
    if (!hasMore) return;
    final current = state.value ?? [];
    final page = (await _fetchRaw(_offset)).map((e) => PostDoc(normalizePost(e))).toList();
    _offset += page.length;
    hasMore = page.length == feedPageSize;
    state = AsyncData([...current, ...page]);
  }
}

final storePostsProvider =
    AsyncNotifierProvider.family<StorePostsNotifier, List<PostDoc>, String>(
      (storeId) => StorePostsNotifier(storeId),
    );

/// Paginated store reels — same shape, `?type=reel`.
class StoreReelsNotifier extends AsyncNotifier<List<PostDoc>> {
  StoreReelsNotifier(this.storeId);

  final String storeId;

  int _offset = 0;
  bool hasMore = true;

  Future<List<Map<String, dynamic>>> _fetchRaw(int offset) async {
    final json = await ref.read(apiClientProvider).get(
      '/stores/$storeId/posts',
      query: {'type': 'reel', 'limit': feedPageSize, 'offset': offset},
    );
    return (json['posts'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
  }

  @override
  Future<List<PostDoc>> build() async {
    _offset = 0;
    hasMore = true;

    final cacheKey = 'store:$storeId:reels:page0';
    final cache = ref.read(readCacheProvider);
    final cached = await cache.readList(cacheKey);
    if (cached != null && cached.isNotEmpty) {
      state = AsyncData(cached.map((e) => PostDoc(normalizePost(e))).toList());
    }

    final raw = await _fetchRaw(0);
    await cache.writeList(cacheKey, raw);
    final posts = raw.map((e) => PostDoc(normalizePost(e))).toList();
    _offset = posts.length;
    hasMore = posts.length == feedPageSize;
    return posts;
  }

  Future<void> loadMore() async {
    if (!hasMore) return;
    final current = state.value ?? [];
    final page = (await _fetchRaw(_offset)).map((e) => PostDoc(normalizePost(e))).toList();
    _offset += page.length;
    hasMore = page.length == feedPageSize;
    state = AsyncData([...current, ...page]);
  }
}

final storeReelsProvider =
    AsyncNotifierProvider.family<StoreReelsNotifier, List<PostDoc>, String>(
      (storeId) => StoreReelsNotifier(storeId),
    );
