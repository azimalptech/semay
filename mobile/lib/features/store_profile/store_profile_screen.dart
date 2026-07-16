import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../post_composer/add_content_sheet.dart';
import '../shared/widgets/error_state_view.dart';
import '../shared/widgets/posts_grid_view.dart';
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
          title: Text(store?['name'] as String? ?? ''),
          actions: [
            if (isOwnStore)
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => context.push('/admin/settings'),
              ),
          ],
        ),
        floatingActionButton: isOwnStore
            ? FloatingActionButton(
                onPressed: () => showAddContentSheet(context, ref, storeId: storeId),
                backgroundColor: AppColors.brand,
                child: const Icon(Icons.add, color: Colors.white),
              )
            : null,
        body: Column(
          children: [
            _StoreHeader(storeId: storeId, store: store, isOwnStore: isOwnStore),
            TabBar(
              labelColor: AppColors.brand,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.brand,
              tabs: [
                Tab(child: _TabLabel(icon: Icons.grid_view, count: postsCount + reelsCount)),
                Tab(child: _TabLabel(icon: Icons.play_circle_outline, count: reelsCount)),
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
  const _TabLabel({required this.icon, required this.count});

  final IconData icon;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 6),
        Text('$count', style: AppTypography.bodySmall.copyWith(color: null)),
      ],
    );
  }
}

class _StoreHeader extends ConsumerWidget {
  const _StoreHeader({required this.storeId, required this.store, required this.isOwnStore});

  final String storeId;
  final Map<String, dynamic>? store;
  final bool isOwnStore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (store == null) return const SizedBox.shrink();
    final s = ref.watch(l10nProvider);

    final avatarUrl = store!['avatarUrl'] as String? ?? '';
    final tagline = store!['tagline'] as String? ?? '';
    final phone = store!['phone'] as String? ?? '';
    final address = store!['address'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          CircleAvatar(
            radius: 40,
            backgroundColor: AppColors.backgroundCard,
            backgroundImage: avatarUrl.isNotEmpty ? CachedNetworkImageProvider(avatarUrl) : null,
            child: avatarUrl.isEmpty
                ? const Icon(Icons.storefront, size: 32, color: AppColors.textMuted)
                : null,
          ),
          if (tagline.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(tagline, style: AppTypography.bodyMedium),
            ),
          if (address.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(address,
                  style: AppTypography.bodySmall.copyWith(color: AppColors.textSecondary)),
            ),
          const SizedBox(height: 12),
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
                      Clipboard.setData(ClipboardData(text: 'semay://store/$storeId'));
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(s.storeLinkCopied)));
                    },
                  ),
                ),
              ] else ...[
                Expanded(
                  child: _PillButton(
                    label: s.message,
                    onTap: () async {
                      final role = await ref.read(appRoleProvider.future);
                      final isAdmin = role == AppRole.admin || role == AppRole.superadmin;
                      final chatId = await ref.read(chatServiceProvider).createOrGetChat(storeId);
                      if (context.mounted) {
                        context.push(isAdmin ? '/admin/chat/$chatId' : '/chat/$chatId');
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _PillButton(
                    label: s.call,
                    onTap: phone.isEmpty
                        ? null
                        : () async {
                            final uri = Uri(scheme: 'tel', path: phone);
                            if (!await launchUrl(uri)) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(SnackBar(content: Text(s.couldNotOpenDialer)));
                              }
                            }
                          },
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Figma: full-width white pill buttons with hairline border ("Edit Profile"
/// / "Share" pair on Store Detail).
class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.backgroundCard,
      shape: const StadiumBorder(side: BorderSide(color: AppColors.borderDivider)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              label,
              style: AppTypography.buttonSmall.copyWith(
                color: onTap == null ? AppColors.textMuted : AppColors.textPrimary,
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
    return postsAsync.when(
      data: (posts) => PostsGridView(
        posts: posts,
        hasMore: ref.read(storePostsProvider(storeId).notifier).hasMore,
        onLoadMore: () => ref.read(storePostsProvider(storeId).notifier).loadMore(),
        onTap: (postId) => context.push('/post/$postId'),
        onRefresh: () async => ref.invalidate(storePostsProvider(storeId)),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) =>
          ErrorStateView(onRetry: () => ref.invalidate(storePostsProvider(storeId))),
    );
  }
}

class _ReelsTab extends ConsumerWidget {
  const _ReelsTab({required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reelsAsync = ref.watch(storeReelsProvider(storeId));
    return reelsAsync.when(
      data: (posts) => PostsGridView(
        posts: posts,
        hasMore: ref.read(storeReelsProvider(storeId).notifier).hasMore,
        onLoadMore: () => ref.read(storeReelsProvider(storeId).notifier).loadMore(),
        onTap: (postId) => context.push('/post/$postId'),
        onRefresh: () async => ref.invalidate(storeReelsProvider(storeId)),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) =>
          ErrorStateView(onRetry: () => ref.invalidate(storeReelsProvider(storeId))),
    );
  }
}
