import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../services/posts_service.dart';
import '../post_interaction_providers.dart';
import 'comments_sheet.dart';

class PostCard extends ConsumerWidget {
  const PostCard({super.key, required this.postId, required this.post});

  final String postId;
  final Map<String, dynamic> post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = post['type'] as String? ?? 'image';
    final mediaUrls = (post['mediaUrls'] as List<dynamic>? ?? []).cast<String>();
    final thumbnailUrl = post['thumbnailUrl'] as String? ?? '';
    final caption = post['caption'] as String? ?? '';

    final isLiked = ref.watch(isLikedProvider(postId)).value ?? false;
    final isSaved = ref.watch(isSavedProvider(postId)).value ?? false;
    final likesCount = post['likesCount'] as int? ?? 0;
    final commentsCount = post['commentsCount'] as int? ?? 0;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: type == 'reel' ? () => context.push('/post/$postId') : null,
            child: AspectRatio(
              aspectRatio: 1,
              child: _PostMedia(type: type, mediaUrls: mediaUrls, thumbnailUrl: thumbnailUrl),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(isLiked ? Icons.favorite : Icons.favorite_border,
                      color: isLiked ? Colors.red : null),
                  onPressed: () => ref.read(postsServiceProvider).toggleLike(postId),
                ),
                Text('$likesCount'),
                IconButton(
                  icon: const Icon(Icons.mode_comment_outlined),
                  onPressed: () => showCommentsSheet(
                    context,
                    postId: postId,
                    postStoreId: post['storeId'] as String? ?? '',
                  ),
                ),
                Text('$commentsCount'),
                const Spacer(),
                IconButton(
                  icon: Icon(isSaved ? Icons.bookmark : Icons.bookmark_border),
                  onPressed: () => ref.read(postsServiceProvider).toggleSave(postId),
                ),
              ],
            ),
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(caption),
            ),
        ],
      ),
    );
  }
}

class _PostMedia extends StatefulWidget {
  const _PostMedia({required this.type, required this.mediaUrls, required this.thumbnailUrl});

  final String type;
  final List<String> mediaUrls;
  final String thumbnailUrl;

  @override
  State<_PostMedia> createState() => _PostMediaState();
}

class _PostMediaState extends State<_PostMedia> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.type == 'reel') {
      final thumb = widget.thumbnailUrl.isNotEmpty ? widget.thumbnailUrl : widget.mediaUrls.first;
      return Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(imageUrl: thumb, fit: BoxFit.cover),
          const Icon(Icons.play_circle_fill, color: Colors.white, size: 56),
        ],
      );
    }

    if (widget.mediaUrls.length == 1) {
      return CachedNetworkImage(imageUrl: widget.mediaUrls.first, fit: BoxFit.cover);
    }

    return Stack(
      children: [
        PageView.builder(
          itemCount: widget.mediaUrls.length,
          onPageChanged: (i) => setState(() => _page = i),
          itemBuilder: (context, i) =>
              CachedNetworkImage(imageUrl: widget.mediaUrls[i], fit: BoxFit.cover),
        ),
        Positioned(
          bottom: 8,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              widget.mediaUrls.length,
              (i) => Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == _page ? Colors.white : Colors.white54,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
