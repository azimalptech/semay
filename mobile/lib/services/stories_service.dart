import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/api_client.dart';
import 'posts_service.dart';

class StoriesService {
  StoriesService(this._api, this._posts);

  final ApiClient _api;
  final PostsService _posts;

  static const _maxVideoBytes = 100 * 1024 * 1024;

  Future<void> createStory({
    required String storeId,
    required XFile mediaFile,
    required String mediaType, // "image" | "video"
  }) async {
    final bytes = await mediaFile.readAsBytes();
    if (mediaType == 'video' && bytes.length > _maxVideoBytes) {
      throw Exception('Video must be under 100MB');
    }
    final isVideo = mediaType == 'video';
    final mediaUrl = await _posts.uploadMedia(
      folder: 'stories',
      bytes: bytes,
      fileExt: isVideo ? 'mp4' : 'jpg',
      contentType: isVideo ? 'video/mp4' : 'image/jpeg',
    );
    await _api.post(
      '/stores/$storeId/stories',
      body: {'mediaUrl': mediaUrl, 'mediaType': mediaType},
    );
  }

  Future<void> deleteStory(String storyId) async {
    await _api.delete('/stories/$storyId');
  }

  /// Marks a store's stories watched-to-the-end for the signed-in user — the
  /// story bar greys that ring out. Called on the last story (see
  /// story_viewer_screen); recordStoryView also stamps this for non-owners,
  /// this covers the owner-viewing-own-store case too.
  Future<void> markStoreSeen(String storeId) async {
    await _api.post('/stores/$storeId/story-seen');
  }

  /// Records a per-story view; the server also stamps user_story_seen for that
  /// store in the same call (replaces the old separate markStoreSeen +
  /// recordStoryView writes — see server recordStoryView).
  Future<void> recordStoryView(String storyId) async {
    await _api.post('/stories/$storyId/view');
  }
}

/// How many unique users watched this story — shown to the owning store's
/// admin in the story viewer footer. No realtime channel for view counts;
/// fetched once when the viewer opens (the count is only shown to the owner,
/// who isn't watching it change live).
final storyViewCountProvider = FutureProvider.family<int, String>((
  ref,
  storyId,
) async {
  final json = await ref.watch(apiClientProvider).get('/stories/$storyId/views');
  return json['count'] as int? ?? 0;
}, isAutoDispose: true);

final storiesServiceProvider = Provider<StoriesService>((ref) {
  return StoriesService(
    ref.watch(apiClientProvider),
    ref.watch(postsServiceProvider),
  );
});
