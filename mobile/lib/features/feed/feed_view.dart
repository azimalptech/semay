import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_icon.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../profile/notifications_providers.dart';
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
          _controller.position.pixels >
              _controller.position.maxScrollExtent - 300) {
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
    final loadingMore = ref.watch(feedLoadingMoreProvider);

    return Scaffold(
      body: Column(
        children: [
          _HomeTopBar(
            onSearch: () => context.push('/search'),
            onNotifications: () => context.push('/settings/notifications'),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () =>
                  ref.read(feedNotifierProvider.notifier).refresh(),
              // hasValue first (not a bare .when()) — refresh()'s
              // copyWithPrevious keeps the old list in .value while a
              // reload is in flight, so pull-to-refresh's own spinner is
              // the only loading indicator the user sees, not a full blank.
              child: feedAsync.hasValue
                  ? ListView(
                      controller: _controller,
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        StoryRingBar(storyRoutePrefix: widget.storyRoutePrefix),
                        if (feedAsync.value!.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(ref.watch(l10nProvider).noPostsYet),
                          ),
                        for (final doc in feedAsync.value!)
                          PostCard(postId: doc.id, post: doc.data()),
                        if (loadingMore)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    )
                  : feedAsync.hasError
                  ? ErrorStateView(
                      onRetry: () =>
                          ref.read(feedNotifierProvider.notifier).refresh(),
                    )
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
        ],
      ),
    );
  }
}

/// Homepage top frame — Figma frame 195:4299, node 195:4300.
class _HomeTopBar extends ConsumerWidget {
  const _HomeTopBar({required this.onSearch, required this.onNotifications});

  final VoidCallback onSearch;
  final VoidCallback onNotifications;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCount = ref.watch(unreadNotificationCountProvider);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundCard,
        border: Border(bottom: BorderSide(color: AppColors.borderDivider)),
      ),
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top,
        bottom: 7,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Text(
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
              icon: AppIcon('search', color: AppColors.textPrimary),
              onPressed: onSearch,
            ),
            IconButton(
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  AppIcon('bell', color: AppColors.textPrimary),
                  if (unreadCount > 0)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        constraints: const BoxConstraints(
                          minWidth: 16,
                          minHeight: 16,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.error,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          unreadCount > 99 ? '99+' : '$unreadCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              onPressed: onNotifications,
            ),
          ],
        ),
      ),
    );
  }
}
