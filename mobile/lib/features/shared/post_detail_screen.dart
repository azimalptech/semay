import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/posts_service.dart';
import 'post_interaction_providers.dart';
import 'widgets/confirm_delete_dialog.dart';
import 'widgets/double_tap_like_overlay.dart';
import 'widgets/edit_caption_dialog.dart';
import 'widgets/reel_player_view.dart';
import 'widgets/send_to_chat_sheet.dart';

/// Full media + interactions for a single post. Reels delegate entirely to
/// ReelPlayerView — the same full-screen layout as the Reels tab — instead of
/// squeezing a vertical video into the square image-post layout below.
class PostDetailScreen extends ConsumerWidget {
  const PostDetailScreen({super.key, required this.postId});

  final String postId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    final postAsync = ref.watch(postDocProvider(postId));

    return postAsync.when(
      data: (post) {
        if (post == null) {
          return Scaffold(
            appBar: AppBar(title: Text(s.post)),
            body: Center(child: Text(s.postNotFound)),
          );
        }
        if (post['type'] == 'reel') {
          return Scaffold(
            backgroundColor: Colors.black,
            body: ReelPlayerView(
              postId: postId,
              post: post,
              isActive: true,
              onClose: () => Navigator.of(context).pop(),
            ),
          );
        }
        return _ImagePostDetail(postId: postId, post: post);
      },
      loading: () => Scaffold(
        appBar: AppBar(title: Text(s.post)),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Scaffold(
        appBar: AppBar(title: Text(s.post)),
        body: Center(child: Text('${s.failedToLoad}: $error')),
      ),
    );
  }
}

class _ImagePostDetail extends ConsumerWidget {
  const _ImagePostDetail({required this.postId, required this.post});

  final String postId;
  final Map<String, dynamic> post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    final mediaUrls = (post['mediaUrls'] as List<dynamic>? ?? []).cast<String>();
    final caption = post['caption'] as String? ?? '';
    final isLiked = ref.watch(isLikedProvider(postId)).value ?? false;
    final isSaved = ref.watch(isSavedProvider(postId)).value ?? false;
    final likesCount = post['likesCount'] as int? ?? 0;
    final storeId = post['storeId'] as String? ?? '';

    final role = ref.watch(appRoleProvider).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    final isOwner =
        (role == AppRole.admin || role == AppRole.superadmin) && storeIds.contains(storeId);

    return Scaffold(
      appBar: AppBar(title: Text(s.post)),
      body: ListView(
        children: [
          DoubleTapLikeOverlay(
            isLiked: isLiked,
            onLike: () => ref.read(postsServiceProvider).toggleLike(postId),
            child: AspectRatio(
              aspectRatio: 1,
              child: PageView(
                children: [
                  for (final url in mediaUrls) CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                ],
              ),
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: Icon(isLiked ? Icons.favorite : Icons.favorite_border,
                    color: isLiked ? Colors.red : null),
                onPressed: () => ref.read(postsServiceProvider).toggleLike(postId),
              ),
              Text('$likesCount'),
              IconButton(
                icon: const Icon(Icons.send_outlined),
                onPressed: () => showSendToChatSheet(
                  context,
                  ref,
                  postId: postId,
                  postStoreId: storeId,
                  postCaption: caption,
                  postMediaUrl: mediaUrls.isNotEmpty ? mediaUrls.first : '',
                ),
              ),
              IconButton(
                icon: const Icon(Icons.share_outlined),
                onPressed: () => SharePlus.instance
                    .share(ShareParams(uri: Uri.parse('semay://post/$postId'))),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(isSaved ? Icons.bookmark : Icons.bookmark_border),
                onPressed: () => ref.read(postsServiceProvider).toggleSave(postId),
              ),
              if (isOwner)
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => showEditCaptionDialog(
                    context,
                    ref,
                    postId: postId,
                    currentCaption: caption,
                  ),
                ),
              if (isOwner)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: AppColors.error),
                  onPressed: () async {
                    final confirmed = await confirmDelete(
                      context,
                      ref,
                      title: s.deletePostTitle,
                      body: s.deletePostBody,
                    );
                    if (!confirmed) return;
                    await ref.read(postsServiceProvider).deletePost(postId);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                ),
            ],
          ),
          if (caption.isNotEmpty)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(caption)),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
