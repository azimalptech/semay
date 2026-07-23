import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../shared/post_interaction_providers.dart';
import 'profile_providers.dart';

enum PostGridKind { liked, saved }

/// Grid of post thumbnails from a list of post IDs — shared by Liked/Saved.
class PostIdGrid extends ConsumerWidget {
  const PostIdGrid({super.key, required this.kind});

  final PostGridKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    final isLiked = kind == PostGridKind.liked;
    final idsAsync = ref.watch(
      isLiked ? likedPostIdsProvider : savedPostIdsProvider,
    );

    return Scaffold(
      appBar: AppBar(title: Text(isLiked ? s.likes : s.saved)),
      body: idsAsync.when(
        data: (ids) {
          if (ids.isEmpty) {
            return Center(
              child: Text(
                isLiked ? s.noLikedYet : s.noSavedYet,
                style: AppTypography.bodyMedium,
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
            itemCount: ids.length,
            itemBuilder: (context, index) => _PostTile(postId: ids[index]),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) =>
            Center(child: Text('${s.failedToLoad}: $error')),
      ),
    );
  }
}

class _PostTile extends ConsumerWidget {
  const _PostTile({required this.postId});

  final String postId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final post = ref.watch(postDocProvider(postId)).value;
    if (post == null) return const SizedBox.shrink();

    final type = post['type'] as String? ?? 'image';
    final thumbnailUrl = post['thumbnailUrl'] as String? ?? '';
    final mediaUrls = (post['mediaUrls'] as List<dynamic>? ?? [])
        .cast<String>();
    final imageUrl = type == 'reel' && thumbnailUrl.isNotEmpty
        ? thumbnailUrl
        : (mediaUrls.isNotEmpty ? mediaUrls.first : '');

    return GestureDetector(
      onTap: () => context.push('/post/$postId'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl.isNotEmpty)
            CachedNetworkImage(imageUrl: imageUrl, fit: BoxFit.cover)
          else
            Container(color: AppColors.borderDivider),
          if (type == 'reel')
            const Positioned(
              top: 4,
              right: 4,
              child: Icon(Icons.movie_outlined, color: Colors.white, size: 18),
            ),
        ],
      ),
    );
  }
}
