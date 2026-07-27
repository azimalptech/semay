import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../services/auth_service.dart';

/// Post IDs the user has liked, newest first — served off post_likes'
/// INDEX(userId, createdAt) (the old users/{uid}/liked mirror is gone; see
/// docs/07_MIGRATION.md). REST + pull-to-refresh.
final likedPostIdsProvider = FutureProvider<List<String>>((ref) async {
  final session = await ref.watch(authStateChangesProvider.future);
  if (session == null) return const [];
  final json = await ref.watch(apiClientProvider).get('/users/me/liked', query: {'limit': 100});
  final posts = (json['posts'] as List<dynamic>? ?? const []);
  return posts.map((p) => (p as Map<String, dynamic>)['id'] as String).toList();
});

/// Post IDs the user has saved, newest first.
final savedPostIdsProvider = FutureProvider<List<String>>((ref) async {
  final session = await ref.watch(authStateChangesProvider.future);
  if (session == null) return const [];
  final json = await ref.watch(apiClientProvider).get('/users/me/saved', query: {'limit': 100});
  final posts = (json['posts'] as List<dynamic>? ?? const []);
  return posts.map((p) => (p as Map<String, dynamic>)['id'] as String).toList();
});
