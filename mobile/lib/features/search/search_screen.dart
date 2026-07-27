import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../feed/feed_providers.dart';
import '../shared/widgets/error_state_view.dart';

/// A single batch of recent posts/reels, filtered client-side by caption as
/// the user types — no substring/full-text query on the server, and this
/// project's scale doesn't warrant standing up a search engine for it. The
/// feed endpoint only returns image/carousel; /reels returns reels — merge
/// both so captions across every post type are searchable.
///
/// The merged list is **shuffled once** here (not newest-first): the search
/// grid is a discovery surface, so it shows a random mix before you type, and
/// the shuffled order is what the post/reel pagers reuse when you tap in (see
/// SearchPostsPagerScreen / SearchReelsPagerScreen). It's a plain (non-
/// autoDispose) FutureProvider, so the shuffle is stable for the whole session
/// until pull-to-refresh invalidates it — it never reshuffles on rebuild.
final searchablePostsProvider = FutureProvider<List<PostDoc>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final results = await Future.wait([
    api.get('/feed', query: {'limit': 100}),
    api.get('/reels', query: {'limit': 100}),
  ]);
  return [...postsFromResponse(results[0]), ...postsFromResponse(results[1])]
    ..shuffle();
});

/// Every active store, filtered client-side by name as the user types — same
/// reasoning as searchablePostsProvider. Stores are a small, bounded set.
final searchableStoresProvider = FutureProvider<List<JsonDoc>>((ref) async {
  final json = await ref.watch(apiClientProvider).get('/stores');
  final list = (json['stores'] as List<dynamic>? ?? const []);
  return list.map((e) => JsonDoc(e as Map<String, dynamic>)).toList();
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
  void initState() {
    super.initState();
    // Reshuffle on every open — searchablePostsProvider shuffles its result, so
    // invalidating it here means each visit to the search page presents a fresh
    // random order (and fresh content). Runs after the first frame so it never
    // fights the initial build's own watch of the provider.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(searchablePostsProvider);
    });
  }

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
        ? const <JsonDoc>[]
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

  final JsonDoc store;

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

  final PostDoc post;

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
      // Open the shuffled pager for this media type (posts vs reels
      // separately), seeded to this tile — not the single-post detail screen.
      onTap: () => context.push(
        type == 'reel' ? '/search/reels/${post.id}' : '/search/posts/${post.id}',
      ),
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
