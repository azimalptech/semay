import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_icon.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../shared/widgets/error_state_view.dart';
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
      body: Column(
        children: [
          _HomeTopBar(onSearch: () => context.push('/search'), onNotifications: () {}),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(feedNotifierProvider.notifier).refresh(),
              child: feedAsync.when(
                data: (posts) => ListView(
                  controller: _controller,
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    StoryRingBar(storyRoutePrefix: widget.storyRoutePrefix),
                    if (posts.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(ref.watch(l10nProvider).noPostsYet),
                      ),
                    for (final doc in posts) PostCard(postId: doc.id, post: doc.data()),
                  ],
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stack) => ErrorStateView(
                  onRetry: () => ref.read(feedNotifierProvider.notifier).refresh(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Homepage top frame — Figma frame 195:4299, node 195:4300.
class _HomeTopBar extends StatelessWidget {
  const _HomeTopBar({required this.onSearch, required this.onNotifications});

  final VoidCallback onSearch;
  final VoidCallback onNotifications;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.backgroundCard,
        border: Border(bottom: BorderSide(color: AppColors.borderDivider)),
      ),
      // Figma 195:4300: the top frame hugs its content — the visible gap to
      // the story bar below comes from the story bar's own padding, not here.
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top, bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Text(
              'SeMay',
              style: TextStyle(
                fontSize: 22,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const AppIcon('search', color: AppColors.textPrimary),
              onPressed: onSearch,
            ),
            IconButton(
              icon: const AppIcon('bell', color: AppColors.textPrimary),
              onPressed: onNotifications,
            ),
          ],
        ),
      ),
    );
  }
}
