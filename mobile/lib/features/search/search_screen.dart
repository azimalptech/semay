import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/firestore_service.dart';
import '../shared/widgets/error_state_view.dart';

/// A single batch of recent posts/reels, filtered client-side by caption as
/// the user types — Firestore has no substring/full-text query, and this
/// project's scale doesn't warrant standing up Algolia or similar for it.
final searchablePostsProvider =
    FutureProvider<List<QueryDocumentSnapshot<Map<String, dynamic>>>>((
      ref,
    ) async {
      final snap = await ref
          .watch(firestoreProvider)
          .collection('posts')
          .orderBy('createdAt', descending: true)
          .limit(200)
          .get();
      return snap.docs;
    });

/// Every active store, filtered client-side by name as the user types — same
/// reasoning as searchablePostsProvider. Stores are a small, bounded
/// collection (unlike posts), so no limit/pagination is needed here.
final searchableStoresProvider =
    FutureProvider<List<QueryDocumentSnapshot<Map<String, dynamic>>>>((
      ref,
    ) async {
      final snap = await ref
          .watch(firestoreProvider)
          .collection('stores')
          .where('active', isEqualTo: true)
          .get();
      return snap.docs;
    });

/// Search entry point from the home top bar — Instagram-style: matches
/// store *names* first (the primary "find this shop" intent) as a tappable
/// list, then post/reel captions as a media grid below, both in one
/// continuous scroll.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final postsAsync = ref.watch(searchablePostsProvider);
    final storesAsync = ref.watch(searchableStoresProvider);

    final matchingStores = _query.isEmpty
        ? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]
        : (storesAsync.value ?? [])
              .where(
                (doc) => (doc.data()['name'] as String? ?? '')
                    .toLowerCase()
                    .contains(_query),
              )
              .toList();

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: s.searchHint,
            border: InputBorder.none,
          ),
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
        ),
      ),
      body: postsAsync.when(
        data: (posts) {
          final matchingPosts = _query.isEmpty
              ? posts
              : posts
                    .where(
                      (doc) => (doc.data()['caption'] as String? ?? '')
                          .toLowerCase()
                          .contains(_query),
                    )
                    .toList();

          if (matchingStores.isEmpty && matchingPosts.isEmpty) {
            return Center(child: Text(s.noSearchResults));
          }

          return CustomScrollView(
            slivers: [
              if (matchingStores.isNotEmpty)
                SliverList.builder(
                  itemCount: matchingStores.length,
                  itemBuilder: (context, index) =>
                      _StoreResultTile(store: matchingStores[index]),
                ),
              if (matchingStores.isNotEmpty && matchingPosts.isNotEmpty)
                SliverToBoxAdapter(
                  child: Divider(height: 1, color: AppColors.borderDivider),
                ),
              if (matchingPosts.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.all(2),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) =>
                          _PostResultTile(post: matchingPosts[index]),
                      childCount: matchingPosts.length,
                    ),
                  ),
                ),
            ],
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

class _StoreResultTile extends StatelessWidget {
  const _StoreResultTile({required this.store});

  final QueryDocumentSnapshot<Map<String, dynamic>> store;

  @override
  Widget build(BuildContext context) {
    final data = store.data();
    final name = data['name'] as String? ?? '';
    final avatarUrl = data['avatarUrl'] as String? ?? '';
    final tagline = data['tagline'] as String? ?? '';

    return ListTile(
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: AppColors.backgroundCard,
        backgroundImage: avatarUrl.isNotEmpty
            ? CachedNetworkImageProvider(avatarUrl)
            : null,
        child: avatarUrl.isEmpty
            ? Icon(Icons.storefront, color: AppColors.textMuted)
            : null,
      ),
      title: Text(name, style: AppTypography.bodyMediumSemibold),
      subtitle: tagline.isNotEmpty
          ? Text(
              tagline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            )
          : null,
      onTap: () => context.push('/store/${store.id}'),
    );
  }
}

class _PostResultTile extends StatelessWidget {
  const _PostResultTile({required this.post});

  final QueryDocumentSnapshot<Map<String, dynamic>> post;

  @override
  Widget build(BuildContext context) {
    final data = post.data();
    final type = data['type'] as String? ?? 'image';
    final thumbnailUrl = data['thumbnailUrl'] as String? ?? '';
    final mediaUrls = (data['mediaUrls'] as List<dynamic>? ?? [])
        .cast<String>();
    final imageUrl = type == 'reel' && thumbnailUrl.isNotEmpty
        ? thumbnailUrl
        : (mediaUrls.isNotEmpty ? mediaUrls.first : '');

    return GestureDetector(
      onTap: () => context.push('/post/${post.id}'),
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
  }
}
