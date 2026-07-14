import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../shared/widgets/posts_grid_view.dart';
import 'store_profile_providers.dart';

/// Store Detail: header (avatar, tagline, phone, address, Message/Call) +
/// Posts/Reels grid tabs. Used for both a plain user's read-only view and an
/// admin browsing another store.
class StoreProfileScreen extends ConsumerWidget {
  const StoreProfileScreen({super.key, required this.storeId});

  final String storeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeDocProvider(storeId)).value;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(title: Text(store?['name'] as String? ?? 'Store')),
        body: Column(
          children: [
            _StoreHeader(storeId: storeId, store: store),
            const TabBar(tabs: [Tab(text: 'Posts'), Tab(text: 'Reels')]),
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

class _StoreHeader extends StatelessWidget {
  const _StoreHeader({required this.storeId, required this.store});

  final String storeId;
  final Map<String, dynamic>? store;

  @override
  Widget build(BuildContext context) {
    if (store == null) return const SizedBox.shrink();

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
            backgroundImage: avatarUrl.isNotEmpty ? CachedNetworkImageProvider(avatarUrl) : null,
            child: avatarUrl.isEmpty ? const Icon(Icons.storefront, size: 32) : null,
          ),
          if (tagline.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(tagline)),
          if (address.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(address, style: Theme.of(context).textTheme.bodySmall),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.message_outlined),
                label: const Text('Message'),
                onPressed: () => context.push('/chat/$storeId'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.call_outlined),
                label: const Text('Call'),
                onPressed: phone.isEmpty
                    ? null
                    : () => ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(phone))),
              ),
            ],
          ),
        ],
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
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text('Error: $error')),
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
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text('Error: $error')),
    );
  }
}
