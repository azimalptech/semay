import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/outbox.dart';
import '../../services/auth_service.dart';

/// Post IDs the user has liked, newest first — served off post_likes'
/// INDEX(userId, createdAt) (the old users/{uid}/liked mirror is gone; see
/// docs/07_MIGRATION.md).
///
/// Kept fresh three ways, because a one-shot keep-alive fetch meant the
/// Liked/Saved grids only ever showed what the user had liked at the moment
/// the app started (the reported bug: liking a post showed up only after
/// force-quitting and reopening):
///  1. auto-disposed, so popping the grid and opening it again refetches;
///  2. [refetchWhenOutboxSends], so a grid already on screen updates the
///     moment the like/unlike reaches the server — including a replay that
///     drains minutes later on bad signal. It has to be the outbox's
///     completion signal: `PostsService.toggleLike` returns after the ENQUEUE,
///     so refetching there would re-cache the pre-toggle list;
///  3. pull-to-refresh on the grid itself (see PostIdGrid).
final likedPostIdsProvider = FutureProvider<List<String>>((ref) async {
  refetchWhenOutboxSends(ref, const {OutboxKind.like, OutboxKind.unlike});
  final session = await ref.watch(authStateChangesProvider.future);
  if (session == null) return const [];
  final json = await ref.watch(apiClientProvider).get('/users/me/liked', query: {'limit': 100});
  final posts = (json['posts'] as List<dynamic>? ?? const []);
  return posts.map((p) => (p as Map<String, dynamic>)['id'] as String).toList();
}, isAutoDispose: true);

/// Post IDs the user has saved, newest first. Refreshed exactly like
/// [likedPostIdsProvider] — same bug, same three mechanisms.
final savedPostIdsProvider = FutureProvider<List<String>>((ref) async {
  refetchWhenOutboxSends(ref, const {OutboxKind.save, OutboxKind.unsave});
  final session = await ref.watch(authStateChangesProvider.future);
  if (session == null) return const [];
  final json = await ref.watch(apiClientProvider).get('/users/me/saved', query: {'limit': 100});
  final posts = (json['posts'] as List<dynamic>? ?? const []);
  return posts.map((p) => (p as Map<String, dynamic>)['id'] as String).toList();
}, isAutoDispose: true);
