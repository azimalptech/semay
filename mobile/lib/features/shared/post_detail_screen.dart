import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../services/auth_service.dart';
import '../../services/posts_service.dart';
import 'post_interaction_providers.dart';
import 'widgets/comments_sheet.dart';

/// Full media + interactions for a single post. Reels get real playback here
/// (unlike the static thumbnail shown in feed cards / grid tiles).
class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({super.key, required this.postId});

  final String postId;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  VideoPlayerController? _videoController;
  String? _initializedUrl;

  void _ensureVideo(String url) {
    if (_initializedUrl == url) return;
    _videoController?.dispose();
    _initializedUrl = url;
    final vc = VideoPlayerController.networkUrl(Uri.parse(url));
    _videoController = vc;
    vc.initialize().then((_) {
      if (mounted) setState(() {});
    });
    vc.setLooping(true);
    vc.play();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final postAsync = ref.watch(postDocProvider(widget.postId));

    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: postAsync.when(
        data: (post) {
          if (post == null) return const Center(child: Text('Post not found'));

          final type = post['type'] as String? ?? 'image';
          final mediaUrls = (post['mediaUrls'] as List<dynamic>? ?? []).cast<String>();
          final caption = post['caption'] as String? ?? '';
          final isLiked = ref.watch(isLikedProvider(widget.postId)).value ?? false;
          final isSaved = ref.watch(isSavedProvider(widget.postId)).value ?? false;
          final likesCount = post['likesCount'] as int? ?? 0;
          final commentsCount = post['commentsCount'] as int? ?? 0;

          final role = ref.watch(appRoleProvider).value;
          final storeIds = ref.watch(storeIdsProvider).value ?? [];
          final isOwner = (role == AppRole.admin || role == AppRole.superadmin) &&
              storeIds.contains(post['storeId']);

          if (type == 'reel' && mediaUrls.isNotEmpty) {
            _ensureVideo(mediaUrls.first);
          }

          return ListView(
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: type == 'reel'
                    ? ((_videoController?.value.isInitialized ?? false)
                        ? GestureDetector(
                            onTap: () => setState(() {
                              _videoController!.value.isPlaying
                                  ? _videoController!.pause()
                                  : _videoController!.play();
                            }),
                            child: FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: _videoController!.value.size.width,
                                height: _videoController!.value.size.height,
                                child: VideoPlayer(_videoController!),
                              ),
                            ),
                          )
                        : const Center(child: CircularProgressIndicator()))
                    : PageView(
                        children: [
                          for (final url in mediaUrls)
                            CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                        ],
                      ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: Icon(isLiked ? Icons.favorite : Icons.favorite_border,
                        color: isLiked ? Colors.red : null),
                    onPressed: () => ref.read(postsServiceProvider).toggleLike(widget.postId),
                  ),
                  Text('$likesCount'),
                  IconButton(
                    icon: const Icon(Icons.mode_comment_outlined),
                    onPressed: () => showCommentsSheet(
                      context,
                      postId: widget.postId,
                      postStoreId: post['storeId'] as String? ?? '',
                    ),
                  ),
                  Text('$commentsCount'),
                  const Spacer(),
                  IconButton(
                    icon: Icon(isSaved ? Icons.bookmark : Icons.bookmark_border),
                    onPressed: () => ref.read(postsServiceProvider).toggleSave(widget.postId),
                  ),
                  if (isOwner)
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await ref.read(postsServiceProvider).deletePost(widget.postId);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                ],
              ),
              if (caption.isNotEmpty)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(caption)),
              const SizedBox(height: 24),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text('Error: $error')),
      ),
    );
  }
}
