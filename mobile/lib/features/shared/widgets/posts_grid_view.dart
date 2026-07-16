import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n.dart';

class PostsGridView extends ConsumerStatefulWidget {
  const PostsGridView({
    super.key,
    required this.posts,
    required this.hasMore,
    required this.onLoadMore,
    required this.onTap,
    this.onRefresh,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> posts;
  final bool hasMore;
  final Future<void> Function() onLoadMore;
  final void Function(String postId) onTap;
  final Future<void> Function()? onRefresh;

  @override
  ConsumerState<PostsGridView> createState() => _PostsGridViewState();
}

class _PostsGridViewState extends ConsumerState<PostsGridView> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (widget.hasMore &&
          _controller.position.pixels > _controller.position.maxScrollExtent - 300) {
        widget.onLoadMore();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grid = widget.posts.isEmpty
        ? Center(
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 64),
                  child: Text(
                    ref.watch(l10nProvider).noPostsYet,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          )
        : GridView.builder(
            controller: _controller,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
            itemCount: widget.posts.length,
            itemBuilder: (context, index) {
              final doc = widget.posts[index];
              final data = doc.data();
              final type = data['type'] as String? ?? 'image';
              final thumbnailUrl = data['thumbnailUrl'] as String? ?? '';
              final mediaUrls = (data['mediaUrls'] as List<dynamic>? ?? []).cast<String>();
              final imageUrl = type == 'reel' && thumbnailUrl.isNotEmpty
                  ? thumbnailUrl
                  : (mediaUrls.isNotEmpty ? mediaUrls.first : '');

              return GestureDetector(
                onTap: () => widget.onTap(doc.id),
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
                        child: Icon(Icons.movie_outlined, color: Colors.white, size: 18),
                      ),
                  ],
                ),
              );
            },
          );

    if (widget.onRefresh == null) return grid;
    return RefreshIndicator(onRefresh: widget.onRefresh!, child: grid);
  }
}
