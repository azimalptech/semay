import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_icon.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../post_composer/add_content_sheet.dart';
import '../shared/widgets/error_state_view.dart';
import '../shared/widgets/posts_grid_view.dart';
import '../story_composer/add_story_flow.dart';
import 'store_posts_pager_screen.dart';
import 'store_profile_providers.dart';

/// Store Detail: header (avatar, tagline, phone, address, actions) +
/// grid/reels tabs with counts (Figma: grid glyph + posts count, play glyph +
/// reels count). "Posts" holds every post type including reels; "Reels" only
/// reels. Own-store admins get Edit Profile/Share instead of Message/Call.
class StoreProfileScreen extends ConsumerWidget {
  const StoreProfileScreen({super.key, required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeDocProvider(storeId)).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    final isOwnStore = storeIds.contains(storeId);
    // "Posts" tab holds every post type including reels, so its own count is
    // postsCount alone (not postsCount + reelsCount, which would double-count
    // reels into both tabs' totals) — the header's own stat row below shows
    // the same two numbers for a consistent "posts vs reels" split at a glance.
    final postsCount = store?['postsCount'] as int? ?? 0;
    final reelsCount = store?['reelsCount'] as int? ?? 0;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          actions: [
            if (isOwnStore)
              IconButton(
                icon: AppIcon('settings', color: AppColors.textPrimary),
                onPressed: () => context.push('/admin/settings'),
              )
            else
              IconButton(
                icon: const Icon(Icons.ios_share_outlined),
                // Real OS share sheet (same as post/reel share), not a silent
                // clipboard copy.
                onPressed: () => SharePlus.instance.share(
                  ShareParams(uri: Uri.parse('semay://store/$storeId')),
                ),
              ),
          ],
        ),
        floatingActionButton: isOwnStore
            ? FloatingActionButton.extended(
                onPressed: () =>
                    showAddContentSheet(context, ref, storeId: storeId),
                backgroundColor: AppColors.brand,
                icon: const AppIcon('plus', color: Colors.white),
                label: Text(
                  ref.watch(l10nProvider).add,
                  style: AppTypography.buttonSmall.copyWith(
                    color: Colors.white,
                  ),
                ),
              )
            : null,
        // NestedScrollView so the whole page scrolls as one: the header
        // collapses away and the tab bar pins to the top, instead of the old
        // fixed header leaving only the grid area (the bottom half) scrollable.
        body: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverToBoxAdapter(
              child: _StoreHeader(
                storeId: storeId,
                store: store,
                isOwnStore: isOwnStore,
                postsCount: postsCount,
                reelsCount: reelsCount,
              ),
            ),
            SliverOverlapAbsorber(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
              sliver: SliverPersistentHeader(
                pinned: true,
                delegate: _TabBarHeaderDelegate(
                  TabBar(
                    labelColor: AppColors.brand,
                    unselectedLabelColor: AppColors.textSecondary,
                    indicatorColor: AppColors.brand,
                    tabs: [
                      Tab(
                        child: _TabLabel(
                          iconName: 'grid',
                          label: ref.watch(l10nProvider).videos,
                        ),
                      ),
                      Tab(
                        child: _TabLabel(
                          iconName: 'play_square',
                          label: ref.watch(l10nProvider).reels,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          body: TabBarView(
            children: [
              _PostsTab(storeId: storeId),
              _ReelsTab(storeId: storeId),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoreHeader extends ConsumerWidget {
  const _StoreHeader({
    required this.storeId,
    required this.store,
    required this.isOwnStore,
    required this.postsCount,
    required this.reelsCount,
  });

  final String storeId;
  final Map<String, dynamic>? store;
  final bool isOwnStore;
  final int postsCount;
  final int reelsCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (store == null) return const SizedBox.shrink();
    final s = ref.watch(l10nProvider);

    final avatarUrl = store!['avatarUrl'] as String? ?? '';
    final name = store!['name'] as String? ?? '';
    final tagline = store!['tagline'] as String? ?? '';
    final phone = store!['phone'] as String? ?? '';
    final address = store!['address'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Same gradient-ring treatment as the story bar's avatars
              // (AppColors.storyGradient) — static here, no spin, since this
              // isn't indicating unseen-story state.
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(colors: AppColors.storyGradient),
                    ),
                    // radius 41 (→ 82px avatar) + 4px ring = 90px total, matching
                    // the home story-bar ring (story_ring_bar.dart's 90×90 box).
                    child: CircleAvatar(
                      radius: 41,
                      backgroundColor: AppColors.backgroundCard,
                      backgroundImage: avatarUrl.isNotEmpty
                          ? CachedNetworkImageProvider(avatarUrl)
                          : null,
                      child: avatarUrl.isEmpty
                          ? Icon(
                              Icons.storefront,
                              size: 40,
                              color: AppColors.textMuted,
                            )
                          : null,
                    ),
                  ),
                  // Add-story entry point (Figma 223:7107 — see
                  // add_story_flow.dart's own doc comment referencing this
                  // exact badge), own-store only.
                  if (isOwnStore)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: GestureDetector(
                        onTap: () =>
                            showAddStorySheet(context, ref, storeId: storeId),
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.brand,
                            border: Border.all(
                              color: AppColors.backgroundPrimary,
                              width: 1.5,
                            ),
                          ),
                          child: const Icon(
                            Icons.add,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, style: AppTypography.titleLarge),
                    const SizedBox(height: 6),
                    // Moved up next to the avatar/name (was previously only
                    // shown as small tab-bar labels further down) — the two
                    // numbers people scan for first, Instagram-style.
                    Row(
                      children: [
                        _StatBlock(count: postsCount, label: s.posts),
                        const SizedBox(width: 40),
                        _StatBlock(count: reelsCount, label: s.reels),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (tagline.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              tagline,
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              if (isOwnStore) ...[
                Expanded(
                  child: _PillButton(
                    label: s.editProfile,
                    onTap: () => context.push('/admin/store/$storeId/edit'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _PillButton(
                    label: s.share,
                    onTap: () => SharePlus.instance.share(
                      ShareParams(uri: Uri.parse('semay://store/$storeId')),
                    ),
                  ),
                ),
              ] else ...[
                Expanded(
                  child: _PillButton(
                    label: s.message,
                    onTap: () async {
                      final role = await ref.read(appRoleProvider.future);
                      final isAdmin =
                          role == AppRole.admin || role == AppRole.superadmin;
                      final chatId = await ref
                          .read(chatServiceProvider)
                          .createOrGetChat(storeId);
                      if (context.mounted) {
                        context.push(
                          isAdmin ? '/admin/chat/$chatId' : '/chat/$chatId',
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _PillButton(
                    label: s.call,
                    filled: true,
                    onTap: phone.isEmpty
                        ? null
                        : () async {
                            final uri = Uri(scheme: 'tel', path: phone);
                            if (!await launchUrl(uri)) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(s.couldNotOpenDialer)),
                                );
                              }
                            }
                          },
                  ),
                ),
              ],
            ],
          ),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 16),
            _InfoRow(iconName: 'phone', label: s.phoneNumber, value: phone),
          ],
          if (address.isNotEmpty) ...[
            const SizedBox(height: 12),
            _InfoRow(iconName: 'location', label: s.address, value: address),
          ],
        ],
      ),
    );
  }
}

/// Tab bar label: icon + text side by side ("▦ Videos" / "▷ Reels").
class _TabLabel extends StatelessWidget {
  const _TabLabel({required this.iconName, required this.label});

  final String iconName;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(iconName, size: 18, color: IconTheme.of(context).color),
        const SizedBox(width: 6),
        Text(label, style: AppTypography.bodySmall.copyWith(color: null)),
      ],
    );
  }
}

/// "24 Posts" / "13 Reels" stat block — count bold above, label muted below,
/// matching the pattern _InfoRow uses for Phone/Location further down.
class _StatBlock extends StatelessWidget {
  const _StatBlock({required this.count, required this.label});

  final int count;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$count',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        Text(
          label,
          style: AppTypography.caption.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.iconName,
    required this.label,
    required this.value,
  });

  final String iconName;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIcon(iconName, size: 20, color: AppColors.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
              Text(value, style: AppTypography.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}

/// Figma: full-width pill buttons on Store Detail — hairline-bordered white
/// by default ("Edit Profile" / "Share" / "Message"), solid [callGreen] when
/// [filled] (the "Call" action specifically — reads as a call button
/// everywhere else in the app too, deliberately distinct from [brand]).
class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Material(
      color: filled && !disabled
          ? AppColors.callGreen
          : AppColors.backgroundCard,
      shape: StadiumBorder(
        side: filled
            ? BorderSide.none
            : BorderSide(color: AppColors.borderDivider),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              label,
              style: AppTypography.buttonSmall.copyWith(
                color: disabled
                    ? AppColors.textMuted
                    : (filled
                          ? AppColors.textOnPrimary
                          : AppColors.textPrimary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pins the profile's grid/reels TabBar to the top of the NestedScrollView as
/// the header above it scrolls away. Solid background so grid rows scroll under
/// it rather than showing through.
class _TabBarHeaderDelegate extends SliverPersistentHeaderDelegate {
  _TabBarHeaderDelegate(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(color: AppColors.backgroundPrimary, child: tabBar);
  }

  @override
  bool shouldRebuild(_TabBarHeaderDelegate oldDelegate) =>
      oldDelegate.tabBar != tabBar;
}

class _PostsTab extends ConsumerWidget {
  const _PostsTab({required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final postsAsync = ref.watch(storePostsProvider(storeId));
    final overlapHandle = NestedScrollView.sliverOverlapAbsorberHandleFor(context);
    // hasValue first (not a bare .when()) — ref.invalidate() preserves the
    // previous list in .value while it reloads, so without this check
    // pull-to-refresh blanks the whole grid to a spinner every time.
    if (postsAsync.hasValue) {
      final posts = postsAsync.value!;
      return PostsGridView(
        posts: posts,
        overlapHandle: overlapHandle,
        storageKey: const PageStorageKey('store_posts_grid'),
        hasMore: ref.read(storePostsProvider(storeId).notifier).hasMore,
        onLoadMore: () =>
            ref.read(storePostsProvider(storeId).notifier).loadMore(),
        onTap: (postId) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => StorePostsPagerScreen(
              storeId: storeId,
              initialPostId: postId,
              reelsOnly: false,
            ),
          ),
        ),
        onRefresh: () async => ref.invalidate(storePostsProvider(storeId)),
      );
    }
    if (postsAsync.hasError) {
      return ErrorStateView(
        onRetry: () => ref.invalidate(storePostsProvider(storeId)),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}

class _ReelsTab extends ConsumerWidget {
  const _ReelsTab({required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reelsAsync = ref.watch(storeReelsProvider(storeId));
    final overlapHandle = NestedScrollView.sliverOverlapAbsorberHandleFor(context);
    if (reelsAsync.hasValue) {
      final posts = reelsAsync.value!;
      return PostsGridView(
        posts: posts,
        overlapHandle: overlapHandle,
        storageKey: const PageStorageKey('store_reels_grid'),
        hasMore: ref.read(storeReelsProvider(storeId).notifier).hasMore,
        onLoadMore: () =>
            ref.read(storeReelsProvider(storeId).notifier).loadMore(),
        onTap: (postId) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => StorePostsPagerScreen(
              storeId: storeId,
              initialPostId: postId,
              reelsOnly: true,
            ),
          ),
        ),
        onRefresh: () async => ref.invalidate(storeReelsProvider(storeId)),
      );
    }
    if (reelsAsync.hasError) {
      return ErrorStateView(
        onRetry: () => ref.invalidate(storeReelsProvider(storeId)),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}
