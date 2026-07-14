import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../shared/widgets/post_card.dart';
import '../shared/widgets/story_ring_bar.dart';
import 'feed_providers.dart';

/// Global discovery feed content shared by the User Home tab and Admin Home
/// tab — docs: "Admin can browse like a normal user too."
class FeedView extends ConsumerStatefulWidget {
  const FeedView({super.key, required this.storyRoutePrefix});

  final String storyRoutePrefix;

  @override
  ConsumerState<FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends ConsumerState<FeedView> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final notifier = ref.read(feedNotifierProvider.notifier);
      if (notifier.hasMore &&
          _controller.position.pixels > _controller.position.maxScrollExtent - 300) {
        notifier.loadMore();
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
    final feedAsync = ref.watch(feedNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SeMay'),
        actions: [
          IconButton(icon: const Icon(Icons.add_box_outlined), onPressed: () => context.push('/compose')),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(feedNotifierProvider.notifier).refresh(),
        child: feedAsync.when(
          data: (posts) => ListView(
            controller: _controller,
            children: [
              StoryRingBar(storyRoutePrefix: widget.storyRoutePrefix),
              if (posts.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Text('No posts yet')),
              for (final doc in posts)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: PostCard(postId: doc.id, post: doc.data()),
                ),
            ],
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(child: Text('Failed to load feed: $error')),
        ),
      ),
    );
  }
}
