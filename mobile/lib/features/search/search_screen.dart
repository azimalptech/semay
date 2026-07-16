import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../services/firestore_service.dart';
import '../shared/widgets/error_state_view.dart';
import '../shared/widgets/posts_grid_view.dart';

/// A single batch of recent posts/reels, filtered client-side by caption as
/// the user types — Firestore has no substring/full-text query, and this
/// project's scale doesn't warrant standing up Algolia or similar for it.
final searchablePostsProvider =
    FutureProvider<List<QueryDocumentSnapshot<Map<String, dynamic>>>>((ref) async {
  final snap = await ref
      .watch(firestoreProvider)
      .collection('posts')
      .orderBy('createdAt', descending: true)
      .limit(200)
      .get();
  return snap.docs;
});

/// Search entry point from the home top bar — results are always the media
/// grid (posts/reels matched by caption), never a text list of accounts or
/// hashtags.
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

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: s.searchHint,
            border: InputBorder.none,
          ),
          onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
        ),
      ),
      body: postsAsync.when(
        data: (posts) {
          final results = _query.isEmpty
              ? posts
              : posts
                  .where((doc) =>
                      (doc.data()['caption'] as String? ?? '').toLowerCase().contains(_query))
                  .toList();
          if (results.isEmpty) {
            return Center(child: Text(s.noSearchResults));
          }
          return PostsGridView(
            posts: results,
            hasMore: false,
            onLoadMore: () async {},
            onTap: (postId) => context.push('/post/$postId'),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ErrorStateView(onRetry: () => ref.invalidate(searchablePostsProvider)),
      ),
    );
  }
}
