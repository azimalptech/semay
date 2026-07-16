import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../shared/post_detail_screen.dart';
import '../shared/widgets/error_state_view.dart';
import '../shared/widgets/reel_player_view.dart';
import 'store_profile_providers.dart';

/// Tapping a tile in a store's grid opens this instead of a single static
/// post: a vertical swipe-through-the-grid pager (Instagram's profile-grid
/// behavior), starting on the tapped post. [reelsOnly] picks the same
/// provider the tapped grid was showing (Posts tab = everything, Reels tab
/// = reels only), so paging through matches what was actually on screen.
class StorePostsPagerScreen extends ConsumerStatefulWidget {
  const StorePostsPagerScreen({
    super.key,
    required this.storeId,
    required this.initialPostId,
    required this.reelsOnly,
  });

  final String storeId;
  final String initialPostId;
  final bool reelsOnly;

  @override
  ConsumerState<StorePostsPagerScreen> createState() => _StorePostsPagerScreenState();
}

class _StorePostsPagerScreenState extends ConsumerState<StorePostsPagerScreen> {
  int _activeIndex = 0;
  bool _initialized = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final postsAsync = widget.reelsOnly
        ? ref.watch(storeReelsProvider(widget.storeId))
        : ref.watch(storePostsProvider(widget.storeId));

    return Scaffold(
      appBar: AppBar(title: Text(s.post)),
      body: postsAsync.when(
        data: (posts) {
          if (posts.isEmpty) return Center(child: Text(s.postNotFound));
          if (!_initialized) {
            final tappedIndex = posts.indexWhere((doc) => doc.id == widget.initialPostId);
            _activeIndex = tappedIndex >= 0 ? tappedIndex : 0;
            _initialized = true;
          }
          if (_activeIndex >= posts.length) _activeIndex = posts.length - 1;

          return PageView.builder(
            scrollDirection: Axis.vertical,
            controller: PageController(initialPage: _activeIndex),
            itemCount: posts.length,
            onPageChanged: (index) => setState(() => _activeIndex = index),
            itemBuilder: (context, index) {
              final doc = posts[index];
              final data = doc.data();
              if (data['type'] == 'reel') {
                return ColoredBox(
                  color: Colors.black,
                  child: ReelPlayerView(
                    postId: doc.id,
                    post: data,
                    isActive: index == _activeIndex,
                  ),
                );
              }
              return SingleChildScrollView(
                child: ImagePostDetailContent(postId: doc.id, post: data),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ErrorStateView(
          onRetry: () => ref.invalidate(
            widget.reelsOnly ? storeReelsProvider(widget.storeId) : storePostsProvider(widget.storeId),
          ),
        ),
      ),
    );
  }
}
