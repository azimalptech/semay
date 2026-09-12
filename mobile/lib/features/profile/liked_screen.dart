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
    final provider = isLiked ? likedPostIdsProvider : savedPostIdsProvider;
    final idsAsync = ref.watch(provider);

    return Scaffold(
      appBar: AppBar(title: Text(isLiked ? s.likes : s.saved)),
      // The provider already refetches on re-entry and whenever the outbox
      // reports a like/save reaching the server; this is the manual escape
      // hatch for "I liked it on my other phone". `.when` keeps showing the
      // current grid while the refetch is in flight (skipLoadingOnRefresh),
      // so the pull spinner is the only loading cue.
      body: RefreshIndicator(
        onRefresh: () async {
          final refreshed = ref.refresh(provider.future);
          try {
            await refreshed;
          } catch (_) {
            // A pull must never throw out of the indicator, and (skipError
            // below) it no longer wipes the grid either — so this is the
            // only place the user hears that their manual refresh failed.
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(s.failedToLoad)),
              );
            }
          }
        },
        child: idsAsync.when(
          // Only report an error when there is nothing else to show. This
          // provider now refetches on its own — 400 ms after the outbox says
          // a like/save reached the server, which on bad signal is exactly
          // when a GET is most likely to fail — and `.when` routes an
          // AsyncError to `error` even when the previous list is still in
          // `.value` (skipError defaults to false). Without this, a transient
          // 5xx replaced the grid the user was looking at with an error page,
          // with the user having done nothing at all. A first load that fails
          // has no previous value, so it still shows the error.
          skipError: true,
          data: (ids) {
            if (ids.isEmpty) {
              return _PullableMessage(
                message: isLiked ? s.noLikedYet : s.noSavedYet,
              );
            }
            return GridView.builder(
              // Without this a grid shorter than the screen can't be pulled.
              physics: const AlwaysScrollableScrollPhysics(),
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
              _PullableMessage(message: '${s.failedToLoad}: $error'),
        ),
      ),
    );
  }
}

/// A centred message that is still a scrollable, so the empty and error states
/// can be pulled down to retry like the grid can.
class _PullableMessage extends StatelessWidget {
  const _PullableMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: constraints.maxHeight,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: AppTypography.bodyMedium,
                ),
              ),
            ),
          ),
        ],
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
