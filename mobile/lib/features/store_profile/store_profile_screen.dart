import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_icon.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../post_composer/add_content_sheet.dart';
import '../shared/widgets/error_state_view.dart';
import '../shared/widgets/posts_grid_view.dart';
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
              Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.ios_share_outlined),
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(text: 'semay://store/$storeId'),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(ref.read(l10nProvider).storeLinkCopied),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
        floatingActionButton: isOwnStore
            ? FloatingActionButton(
                onPressed: () =>
                    showAddContentSheet(context, ref, storeId: storeId),
                backgroundColor: AppColors.brand,
                child: const AppIcon('plus', color: Colors.white),
              )
            : null,
        body: Column(
          children: [
            _StoreHeader(
              storeId: storeId,
              store: store,
              isOwnStore: isOwnStore,
            ),
            TabBar(
              labelColor: AppColors.brand,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.brand,
              tabs: [
                Tab(
                  child: _TabLabel(
                    iconName: 'grid',
                    count: postsCount + reelsCount,
                  ),
                ),
                Tab(
                  child: _TabLabel(iconName: 'play_square', count: reelsCount),
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _PostsTab(storeId: storeId),
                  _ReelsTab(storeId: storeId),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({required this.iconName, required this.count});

  final String iconName;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(iconName, size: 20, color: IconTheme.of(context).color),
        const SizedBox(width: 6),
        Text('$count', style: AppTypography.bodySmall.copyWith(color: null)),
      ],
    );
  }
}

class _StoreHeader extends ConsumerWidget {
  const _StoreHeader({
    required this.storeId,
    required this.store,
    required this.isOwnStore,
  });

  final String storeId;
  final Map<String, dynamic>? store;
  final bool isOwnStore;

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
              Container(
                padding: const EdgeInsets.all(2.5),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(colors: AppColors.storyGradient),
                ),
                child: CircleAvatar(
                  radius: 32,
                  backgroundColor: AppColors.backgroundCard,
                  backgroundImage: avatarUrl.isNotEmpty
                      ? CachedNetworkImageProvider(avatarUrl)
                      : null,
                  child: avatarUrl.isEmpty
                      ? Icon(
                          Icons.storefront,
                          size: 28,
                          color: AppColors.textMuted,
                        )
                      : null,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, style: AppTypography.titleLarge),
                    if (tagline.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          tagline,
                          style: AppTypography.bodySmall.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
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
                    onTap: () {
                      Clipboard.setData(
                        ClipboardData(text: 'semay://store/$storeId'),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(s.storeLinkCopied)),
                      );
                    },
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

/// "Phone" / "Location" labeled rows below the action buttons (Figma Store
/// Detail) — small muted label on top, value below, leading icon.
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

class _PostsTab extends ConsumerWidget {
  const _PostsTab({required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final postsAsync = ref.watch(storePostsProvider(storeId));
    // hasValue first (not a bare .when()) — ref.invalidate() preserves the
    // previous list in .value while it reloads, so without this check
    // pull-to-refresh blanks the whole grid to a spinner every time.
    if (postsAsync.hasValue) {
      final posts = postsAsync.value!;
      return PostsGridView(
        posts: posts,
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
    if (reelsAsync.hasValue) {
      final posts = reelsAsync.value!;
      return PostsGridView(
        posts: posts,
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
