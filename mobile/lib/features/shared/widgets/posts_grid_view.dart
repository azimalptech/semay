import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n.dart';
import '../../feed/feed_providers.dart';

/// Store-profile media grid. A sliver-based [CustomScrollView] (not a plain
/// GridView) with no scroll controller of its own, so it coordinates with the
/// ancestor [NestedScrollView] in StoreProfileScreen — that's what lets the
/// whole page scroll as one (the header collapses away, the tab bar pins)
/// instead of only the grid area scrolling under a fixed header. [overlapHandle]
/// is the NestedScrollView's overlap handle, injected so the pinned tab bar
/// doesn't cover the first grid row.
class PostsGridView extends ConsumerWidget {
  const PostsGridView({
    super.key,
    required this.posts,
    required this.hasMore,
    required this.onLoadMore,
    required this.onTap,
    this.onRefresh,
    this.overlapHandle,
    this.storageKey,
  });

  final List<PostDoc> posts;
  final bool hasMore;
  final Future<void> Function() onLoadMore;
  final void Function(String postId) onTap;
  final Future<void> Function()? onRefresh;
  final SliverOverlapAbsorberHandle? overlapHandle;
  final PageStorageKey<String>? storageKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Load-more via scroll notifications rather than a private ScrollController,
    // because inside a NestedScrollView the grid is driven by the shared inner
    // controller — a controller of our own wouldn't see that scrolling at all.
    final scrollView = NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (hasMore &&
            n.metrics.axis == Axis.vertical &&
            n.metrics.pixels > n.metrics.maxScrollExtent - 300) {
          onLoadMore();
        }
        return false;
      },
      child: CustomScrollView(
        key: storageKey,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (overlapHandle != null)
            SliverOverlapInjector(handle: overlapHandle!),
          if (posts.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 64),
                  child: Text(
                    ref.watch(l10nProvider).noPostsYet,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.all(2),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 2,
                  mainAxisSpacing: 2,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final doc = posts[index];
                  final data = doc.data();
                  final type = data['type'] as String? ?? 'image';
                  final thumbnailUrl = data['thumbnailUrl'] as String? ?? '';
                  final mediaUrls = (data['mediaUrls'] as List<dynamic>? ?? [])
                      .cast<String>();
                  final imageUrl = type == 'reel' && thumbnailUrl.isNotEmpty
                      ? thumbnailUrl
                      : (mediaUrls.isNotEmpty ? mediaUrls.first : '');

                  return GestureDetector(
                    onTap: () => onTap(doc.id),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (imageUrl.isNotEmpty)
                          CachedNetworkImage(imageUrl: imageUrl, fit: BoxFit.cover)
                        else
                          Container(color: Colors.grey.shade300),
                        if (type == 'reel')
                          const Positioned(
                            top: 4,
                            right: 4,
                            child: Icon(
                              Icons.movie_outlined,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                      ],
                    ),
                  );
                }, childCount: posts.length),
              ),
            ),
        ],
      ),
    );

    if (onRefresh == null) return scrollView;
    return RefreshIndicator(onRefresh: onRefresh!, child: scrollView);
  }
}
