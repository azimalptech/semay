import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/l10n.dart';
import '../../services/auth_service.dart';
import '../shared/widgets/error_state_view.dart';
import '../shared/widgets/post_card.dart';
import '../shared/widgets/reel_player_view.dart';
import 'search_screen.dart' show searchablePostsProvider;

/// Whether the signed-in user owns this post's store (admin/superadmin of it) —
/// controls PostCard's owner actions. Unlike the store grid pager, search mixes
/// every store's posts, so ownership is decided per-post, not once per screen.
bool _ownsPost(WidgetRef ref, Map<String, dynamic> post) {
  final role = ref.watch(appRoleProvider).value;
  if (role != AppRole.admin && role != AppRole.superadmin) return false;
  final storeIds = ref.watch(storeIdsProvider).value ?? const [];
  return storeIds.contains(post['storeId'] as String? ?? '');
}

/// Tapping an image/carousel tile in the search grid opens this: a continuously
/// scrollable feed of every image/carousel post (same PostCard the Home tab
/// uses), in the search grid's already-shuffled order, scrolled to the tapped
/// post. Reels are handled separately by SearchReelsPagerScreen — "posts and
/// reels, separately", per the product request.
class SearchPostsPagerScreen extends ConsumerStatefulWidget {
  const SearchPostsPagerScreen({super.key, required this.initialPostId});

  final String initialPostId;

  @override
  ConsumerState<SearchPostsPagerScreen> createState() =>
      _SearchPostsPagerScreenState();
}

class _SearchPostsPagerScreenState
    extends ConsumerState<SearchPostsPagerScreen> {
  final _itemScrollController = ItemScrollController();
  bool _scrolledToInitial = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final postsAsync = ref.watch(searchablePostsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(s.post)),
      body: postsAsync.when(
        data: (all) {
          // Keep the shuffled order from the grid; just drop reels.
          final posts = all
              .where((doc) => (doc.data()['type'] as String? ?? '') != 'reel')
              .toList();
          if (posts.isEmpty) return Center(child: Text(s.postNotFound));

          if (!_scrolledToInitial) {
            _scrolledToInitial = true;
            final tappedIndex = posts.indexWhere(
              (doc) => doc.id == widget.initialPostId,
            );
            if (tappedIndex > 0) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_itemScrollController.isAttached) {
                  _itemScrollController.jumpTo(index: tappedIndex);
                }
              });
            }
          }

          return ScrollablePositionedList.builder(
            itemScrollController: _itemScrollController,
            itemCount: posts.length,
            itemBuilder: (context, index) {
              final doc = posts[index];
              return PostCard(
                postId: doc.id,
                post: doc.data(),
                showOwnerActions: _ownsPost(ref, doc.data()),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ErrorStateView(
          onRetry: () => ref.invalidate(searchablePostsProvider),
        ),
      ),
    );
  }
}

/// Tapping a reel tile in the search grid opens this: a full-screen vertical
/// pager over every reel, in the search grid's already-shuffled order, seeded
/// to the tapped reel — the same swipe-through behavior as the Reels tab, just
/// shuffled and starting where the user tapped.
class SearchReelsPagerScreen extends ConsumerStatefulWidget {
  const SearchReelsPagerScreen({super.key, required this.initialPostId});

  final String initialPostId;

  @override
  ConsumerState<SearchReelsPagerScreen> createState() =>
      _SearchReelsPagerScreenState();
}

class _SearchReelsPagerScreenState
    extends ConsumerState<SearchReelsPagerScreen> {
  PageController? _pageController;
  int _activeIndex = 0;
  bool _visible = true;

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final postsAsync = ref.watch(searchablePostsProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: VisibilityDetector(
        key: const Key('search-reels-pager'),
        onVisibilityChanged: (info) {
          if (!mounted) return;
          final visible = info.visibleFraction > 0;
          if (visible != _visible) setState(() => _visible = visible);
        },
        child: postsAsync.when(
          data: (all) {
            final reels = all
                .where((doc) => (doc.data()['type'] as String? ?? '') == 'reel')
                .toList();
            if (reels.isEmpty) {
              return Center(
                child: Text(
                  s.noReelsYet,
                  style: const TextStyle(color: Colors.white),
                ),
              );
            }

            if (_pageController == null) {
              final startIndex = reels.indexWhere(
                (doc) => doc.id == widget.initialPostId,
              );
              _activeIndex = startIndex < 0 ? 0 : startIndex;
              _pageController = PageController(initialPage: _activeIndex);
            }
            if (_activeIndex >= reels.length) _activeIndex = reels.length - 1;

            return PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: reels.length,
              onPageChanged: (index) => setState(() => _activeIndex = index),
              itemBuilder: (context, index) => ReelPlayerView(
                postId: reels[index].id,
                post: reels[index].data(),
                isActive: index == _activeIndex && _visible,
                onClose: () => Navigator.of(context).pop(),
              ),
            );
          },
          loading: () =>
              const Center(child: CircularProgressIndicator(color: Colors.white)),
          error: (error, stack) => Center(
            child: Text(
              '${s.failedToLoad}: $error',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
