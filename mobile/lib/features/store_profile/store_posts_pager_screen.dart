import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../core/l10n.dart';
import '../../services/auth_service.dart';
import '../shared/widgets/error_state_view.dart';
import '../shared/widgets/post_card.dart';
import 'store_profile_providers.dart';

/// Tapping a tile in a store's grid opens this instead of a single static
/// post: a continuously scrollable feed (same PostCard widget the Home tab
/// uses, so images/carousels/reels all render exactly like Home — no
/// page-snapping), scrolled to the tapped post's position on open.
/// [reelsOnly] picks the same provider the tapped grid was showing (Posts
/// tab = everything, Reels tab = reels only).
class StorePostsPagerScreen extends ConsumerStatefulWidget {
  const StorePostsPagerScreen({
    super.key,
    required this.storeId,
    required this.initialPostId,
    required this.reelsOnly,
  });

  final String storeId;
  final String initialPostId;
  final bool reelsOnly;

  @override
  ConsumerState<StorePostsPagerScreen> createState() =>
      _StorePostsPagerScreenState();
}

class _StorePostsPagerScreenState extends ConsumerState<StorePostsPagerScreen> {
  final _itemScrollController = ItemScrollController();
  bool _scrolledToInitial = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final postsAsync = widget.reelsOnly
        ? ref.watch(storeReelsProvider(widget.storeId))
        : ref.watch(storePostsProvider(widget.storeId));
    final role = ref.watch(appRoleProvider).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    final isOwner =
        (role == AppRole.admin || role == AppRole.superadmin) &&
        storeIds.contains(widget.storeId);

    return Scaffold(
      appBar: AppBar(title: Text(s.post)),
      body: postsAsync.when(
        data: (posts) {
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
                showOwnerActions: isOwner,
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ErrorStateView(
          onRetry: () => ref.invalidate(
            widget.reelsOnly
                ? storeReelsProvider(widget.storeId)
                : storePostsProvider(widget.storeId),
          ),
        ),
      ),
    );
  }
}
