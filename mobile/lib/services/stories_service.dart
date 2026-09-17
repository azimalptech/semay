import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/api_client.dart';
import '../core/upload_progress.dart';
import 'posts_service.dart';

class StoriesService {
  StoriesService(this._api, this._posts);

  final ApiClient _api;
  final PostsService _posts;

  static const _maxVideoBytes = 100 * 1024 * 1024;

  /// [onProgress] is the raw `(sent, total)` for THIS file. A multi-file
  /// story publish aggregates the files itself (the preview screen owns the
  /// job total — it knows how many files it is about to publish), so this
  /// deliberately forwards the per-file shape rather than a 0..1 of its own.
  Future<void> createStory({
    required String storeId,
    required XFile mediaFile,
    required String mediaType, // "image" | "video"
    UploadByteProgress? onProgress,
  }) async {
    final bytes = await mediaFile.readAsBytes();
    if (mediaType == 'video' && bytes.length > _maxVideoBytes) {
      throw const MediaTooLargeException(_maxVideoBytes);
    }
    final isVideo = mediaType == 'video';
    final mediaUrl = await _posts.uploadMedia(
      folder: 'stories',
      bytes: bytes,
      fileExt: isVideo ? 'mp4' : 'jpg',
      contentType: isVideo ? 'video/mp4' : 'image/jpeg',
      onProgress: onProgress,
    );
    await _api.post(
      '/stores/$storeId/stories',
      body: {'mediaUrl': mediaUrl, 'mediaType': mediaType},
    );
  }

  Future<void> deleteStory(String storyId) async {
    await _api.delete('/stories/$storyId');
  }

  /// Marks a store's stories watched-to-the-end for the signed-in user — both
  /// story rings (the home bar and the store profile header) grey out. Called
  /// on the LAST story (see story_viewer_screen), and it is the ONLY thing
  /// that sets `seen`: recordStoryView below deliberately does not, or
  /// watching 1 of 3 slides would mute a store with two stories unwatched.
  Future<void> markStoreSeen(String storeId) async {
    await _api.post('/stores/$storeId/story-seen');
  }

  /// Records a per-story view (the owner's "seen by N"). Fired per slide, so
  /// it must NOT imply the store has been watched through — see markStoreSeen
  /// above and server/src/stories/service.ts recordStoryView.
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
