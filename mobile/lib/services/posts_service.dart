import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// XFile comes from share_plus's re-export of cross_file (image_picker, which
// callers use to pick the files, re-exports the same type).
import 'package:share_plus/share_plus.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../core/api_client.dart';
import '../core/interaction_buffer.dart';
import '../core/outbox.dart';

class PostsService {
  PostsService(this._api, this._outbox, this._interactions);

  final ApiClient _api;
  final OutboxService _outbox;
  final InteractionBuffer _interactions;

  static const _maxVideoBytes = 100 * 1024 * 1024;

  /// Requests a presigned upload URL from the API, PUTs the bytes straight to
  /// MinIO, and returns the eventual public URL to store on the post/story
  /// (see docs/07_MIGRATION.md Phase 3's media pipeline). Replaces Firebase
  /// Storage's putData + getDownloadURL. Public so StoriesService/ChatService
  /// reuse the exact same upload path.
  Future<String> uploadMedia({
    required String folder, // "posts" | "stores" | "stories" | "chats"
    required Uint8List bytes,
    required String fileExt, // "jpg" | "mp4"
    required String contentType,
  }) async {
    final slot = await _api.post(
      '/media/upload-url',
      body: {'folder': folder, 'fileExt': fileExt},
    );
    final uploadUrl = slot['uploadUrl'] as String;
    final publicUrl = slot['publicUrl'] as String;
    // Bare Dio (no auth header) — the presigned URL carries its own signature,
    // and MinIO doesn't want our bearer token.
    await Dio().put<void>(
      uploadUrl,
      data: Stream.fromIterable([bytes]),
      options: Options(
        headers: {
          Headers.contentTypeHeader: contentType,
          Headers.contentLengthHeader: bytes.length,
        },
      ),
    );
    return publicUrl;
  }

  Future<void> createPost({
    required String storeId,
    required String type, // "image" | "carousel" | "reel"
    required List<XFile> files,
    required String caption,
    num? price,
  }) async {
    final media = <Map<String, dynamic>>[];
    for (var i = 0; i < files.length; i++) {
      final bytes = await files[i].readAsBytes();
      if (type == 'reel' && bytes.length > _maxVideoBytes) {
        throw Exception('Video must be under 100MB');
      }
      final isReel = type == 'reel';
      final url = await uploadMedia(
        folder: 'posts',
        bytes: bytes,
        fileExt: isReel ? 'mp4' : 'jpg',
        contentType: isReel ? 'video/mp4' : 'image/jpeg',
      );
      media.add({'url': url, 'position': i});
    }

    // video_thumbnail has no web implementation — reels published from a
    // browser get an empty thumbnailUrl and grids fall back to the video URL.
    String thumbnailUrl = '';
    if (type == 'reel' && !kIsWeb) {
      final thumbBytes = await VideoThumbnail.thumbnailData(
        video: files.first.path,
        imageFormat: ImageFormat.JPEG,
      );
      if (thumbBytes != null) {
        thumbnailUrl = await uploadMedia(
          folder: 'posts',
          bytes: thumbBytes,
          fileExt: 'jpg',
          contentType: 'image/jpeg',
        );
      }
    }

    final body = <String, dynamic>{
      'type': type,
      'caption': caption,
      'media': media,
    };
    if (price != null) body['price'] = price;
    if (thumbnailUrl.isNotEmpty) body['thumbnailUrl'] = thumbnailUrl;
    await _api.post('/stores/$storeId/posts', body: body);
  }

  Future<void> deletePost(String postId) async {
    await _api.delete('/posts/$postId');
  }

  /// Instagram scopes post editing to the caption only — the media stays as
  /// uploaded, no re-crop/replace after publish.
  Future<void> updateCaption(String postId, String caption) async {
    await _api.patch('/posts/$postId', body: {'caption': caption});
  }

  /// View/send/share no longer hit the server per tap. They accumulate in the
  /// local InteractionBuffer, which dedups the same user re-counting the same
  /// post within a 30-minute window and flushes batched increments every
  /// ~30 minutes / on app background (see interaction_buffer.dart). Calling
  /// these repeatedly is cheap and safe — a repeat within the window is a
  /// no-op, a tap after it counts again.
  Future<void> recordView(String postId) async {
    await _interactions.record(postId, InteractionKind.view);
  }

  Future<void> recordSent(String postId) async {
    await _interactions.record(postId, InteractionKind.sent);
  }

  Future<void> recordShare(String postId) async {
    await _interactions.record(postId, InteractionKind.share);
  }

  /// Shared by every "share" icon (post_card.dart, post_detail_screen.dart,
  /// reel_player_view.dart) — only records the share if the OS share sheet
  /// reports the user actually completed a share (not dismissed/cancelled).
  /// Returns whether it actually counted, so callers can decide whether to
  /// show a "Shared" confirmation.
  Future<bool> shareAndRecord(String postId) async {
    final result = await SharePlus.instance.share(
      ShareParams(uri: Uri.parse('semay://post/$postId')),
    );
    if (result.status != ShareResultStatus.success) return false;
    await recordShare(postId);
    return true;
  }

  /// Routed through the offline outbox (Phase 9b) so a like/save toggled with
  /// no signal replays on reconnect. like/save are naturally idempotent on the
  /// server (composite PK per (post,user)), so a replayed toggle is safe; the
  /// UI already shows the new state optimistically (see LikeNotifier).
  Future<void> toggleLike(String postId, bool isLiked) async {
    await _outbox.enqueue(
      isLiked ? OutboxKind.like : OutboxKind.unlike,
      {'postId': postId},
    );
  }

  Future<void> toggleSave(String postId, bool isSaved) async {
    await _outbox.enqueue(
      isSaved ? OutboxKind.save : OutboxKind.unsave,
      {'postId': postId},
    );
  }
}

final postsServiceProvider = Provider<PostsService>((ref) {
  return PostsService(
    ref.watch(apiClientProvider),
    ref.watch(outboxServiceProvider),
    ref.watch(interactionBufferProvider),
  );
});
