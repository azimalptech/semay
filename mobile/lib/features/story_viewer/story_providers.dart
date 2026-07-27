import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../feed/feed_providers.dart';

/// That store's active stories, oldest first. The server already filters to
/// non-expired (`expiresAt > now`); the story viewer just needs the ordered
/// list. Uses PostDoc's JsonDoc wrapper so the viewer keeps reading
/// `doc.id` / `doc.data()['mediaUrl']` unchanged.
final storeStoriesProvider = FutureProvider.family<List<PostDoc>, String>((
  ref,
  storeId,
) async {
  final json = await ref.watch(apiClientProvider).get('/stores/$storeId/stories');
  final list = (json['stories'] as List<dynamic>? ?? const []);
  return list.map((e) => PostDoc(e as Map<String, dynamic>)).toList();
}, isAutoDispose: true);
