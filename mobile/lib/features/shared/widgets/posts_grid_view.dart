import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class PostsGridView extends StatefulWidget {
  const PostsGridView({
    super.key,
    required this.posts,
    required this.hasMore,
    required this.onLoadMore,
    required this.onTap,
  });

  final List<QueryDocumentSnapshot<Map<String, dynamic>>> posts;
  final bool hasMore;
  final Future<void> Function() onLoadMore;
  final void Function(String postId) onTap;

  @override
  State<PostsGridView> createState() => _PostsGridViewState();
}

class _PostsGridViewState extends State<PostsGridView> {
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
    if (widget.posts.isEmpty) {
      return const Center(child: Text('No posts yet'));
    }

    return GridView.builder(
      controller: _controller,
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
  }
}
