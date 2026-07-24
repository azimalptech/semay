import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:visibility_detector/visibility_detector.dart';

import '../../core/app_icon.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/posts_service.dart';
import '../reels/reels_screen.dart' show globalReelsProvider;
import 'post_interaction_providers.dart';
import 'widgets/confirm_delete_dialog.dart';
import 'widgets/double_tap_like_overlay.dart';
import 'widgets/edit_caption_dialog.dart';
import 'widgets/pinch_zoom_image.dart';
import 'widgets/reel_player_view.dart';
import 'widgets/send_to_chat_sheet.dart';

/// Full media + interactions for a single post. Reels delegate entirely to
/// ReelPlayerView — the same full-screen layout as the Reels tab — instead of
/// squeezing a vertical video into the square image-post layout below.
class PostDetailScreen extends ConsumerWidget {
  const PostDetailScreen({
    super.key,
    required this.postId,
    this.initialPosition,
  });

  final String postId;
  // Set when opened from a reel already mid-playback in the feed — see
  // ReelPlayerView.initialPosition.
  final Duration? initialPosition;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    debugPrint(
      'post_detail_screen: build postId=$postId canPop=${Navigator.of(context).canPop()}',
    );
    final s = ref.watch(l10nProvider);
    final postAsync = ref.watch(postDocProvider(postId));

    return postAsync.when(
      data: (post) {
        if (post == null) {
          return Scaffold(
            appBar: AppBar(title: Text(s.post)),
            body: Center(child: Text(s.postNotFound)),
          );
        }
        if (post['type'] == 'reel') {
          return Scaffold(
            backgroundColor: Colors.black,
            body: _ReelPager(
              initialPostId: postId,
              initialPost: post,
              initialPosition: initialPosition,
              onClose: () => Navigator.of(context).pop(),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(s.post)),
          body: ListView(
            children: [ImagePostDetailContent(postId: postId, post: post)],
          ),
        );
      },
      loading: () => Scaffold(
        appBar: AppBar(title: Text(s.post)),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Scaffold(
        appBar: AppBar(title: Text(s.post)),
        body: Center(child: Text('${s.failedToLoad}: $error')),
      ),
    );
  }
}

/// Vertical swipe-through-reels pager opened from a single tapped reel —
/// same scroll-to-next-reel behavior as the dedicated Reels tab, just seeded
/// to start on whichever reel the user actually tapped instead of the
/// newest one. Reuses the Reels tab's own feed (globalReelsProvider) so
/// "next reel" here matches what the Reels tab would show next; if the
/// tapped reel has aged out of that feed's most-recent-50 window, it's
/// prepended so the pager still opens on the right video.
class _ReelPager extends ConsumerStatefulWidget {
  const _ReelPager({
    required this.initialPostId,
    required this.initialPost,
    required this.onClose,
    this.initialPosition,
  });

  final String initialPostId;
  final Map<String, dynamic> initialPost;
  final VoidCallback onClose;
  final Duration? initialPosition;

  @override
  ConsumerState<_ReelPager> createState() => _ReelPagerState();
}

class _ReelPagerState extends ConsumerState<_ReelPager> {
  PageController? _pageController;
  int _activeIndex = 0;
  bool _tabVisible = true;

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final reelsAsync = ref.watch(globalReelsProvider);

    return VisibilityDetector(
      key: const Key('reel-pager-detail'),
      onVisibilityChanged: (info) {
        if (!mounted) return;
        final visible = info.visibleFraction > 0;
        if (visible != _tabVisible) setState(() => _tabVisible = visible);
      },
      child: reelsAsync.when(
        data: (reels) {
          var entries = [for (final d in reels) MapEntry(d.id, d.data())];
          if (!entries.any((e) => e.key == widget.initialPostId)) {
            entries = [
              MapEntry(widget.initialPostId, widget.initialPost),
              ...entries,
            ];
          }
          if (_pageController == null) {
            final startIndex = entries.indexWhere(
              (e) => e.key == widget.initialPostId,
            );
            _activeIndex = startIndex < 0 ? 0 : startIndex;
            _pageController = PageController(initialPage: _activeIndex);
          }
          if (_activeIndex >= entries.length) _activeIndex = entries.length - 1;
          return PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: entries.length,
            onPageChanged: (index) => setState(() => _activeIndex = index),
            itemBuilder: (context, index) => ReelPlayerView(
              postId: entries[index].key,
              post: entries[index].value,
              isActive: index == _activeIndex && _tabVisible,
              onClose: widget.onClose,
              // Only the specific reel that was tapped mid-playback resumes
              // from that frame — swiping to any other reel from here still
              // starts fresh, same as every other entry point.
              initialPosition: entries[index].key == widget.initialPostId
                  ? widget.initialPosition
                  : null,
            ),
          );
        },
        loading: () =>
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        error: (error, stack) => Center(
          child: Text(
            '${s.failedToLoad}: $error',
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Media + actions + caption for one image/carousel post — no Scaffold/AppBar
/// of its own, so it can sit either as PostDetailScreen's whole body or as
/// one page of StorePostsPagerScreen's vertical swipe-through-the-grid pager.
class ImagePostDetailContent extends ConsumerStatefulWidget {
  const ImagePostDetailContent({
    super.key,
    required this.postId,
    required this.post,
  });

  final String postId;
  final Map<String, dynamic> post;

  @override
  ConsumerState<ImagePostDetailContent> createState() =>
      _ImagePostDetailContentState();
}

class _ImagePostDetailContentState
    extends ConsumerState<ImagePostDetailContent> {
  Timer? _viewTimer;
  bool _viewRecorded = false;

  @override
  void initState() {
    super.initState();
    // 2s dwell is the baseline signal; _recordView also fires early (and
    // cancels this) the instant they like or pinch-zoom — see the isLiked
    // listen below and PinchZoomImage's onZoomStart. Detail-view only, by
    // product decision — a post merely scrolling past in the main feed
    // never counts, no matter how long it's on screen there.
    _viewTimer = Timer(const Duration(seconds: 2), _recordView);
  }

  @override
  void dispose() {
    _viewTimer?.cancel();
    super.dispose();
  }

  void _recordView() {
    _viewTimer?.cancel();
    if (_viewRecorded) return;
    _viewRecorded = true;
    ref.read(postsServiceProvider).recordView(widget.postId);
  }

  @override
  Widget build(BuildContext context) {
    final postId = widget.postId;
    final post = widget.post;
    final s = ref.watch(l10nProvider);
    ref.listen(likeStateProvider(postId), (previous, next) {
      if (next.isLiked && (previous == null || !previous.isLiked)) {
        _recordView();
      }
    });
    final mediaUrls = (post['mediaUrls'] as List<dynamic>? ?? [])
        .cast<String>();
    final caption = post['caption'] as String? ?? '';
    final likeState = ref.watch(likeStateProvider(postId));
    final isLiked = likeState.isLiked;
    final isSaved = ref.watch(isSavedProvider(postId)).value ?? false;
    final likesCount = likeState.likesCount;
    final storeId = post['storeId'] as String? ?? '';

    final role = ref.watch(appRoleProvider).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    final isOwner =
        (role == AppRole.admin || role == AppRole.superadmin) &&
        storeIds.contains(storeId);
    final store = ref.watch(storeSummaryProvider(storeId)).value;
    final storeName = store?['name'] as String? ?? '';
    final storeAvatarUrl = store?['avatarUrl'] as String? ?? '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Opened from anywhere other than the Home feed (search results,
        // Liked/Saved, a shared-post chat bubble) landed here with no way
        // to reach the store's profile at all — PostCard's feed row has
        // this same tappable avatar+name, this was just missing from the
        // detail screen entirely for image/carousel posts (reels already
        // have their own equivalent in ReelPlayerView).
        if (storeId.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => context.push('/store/$storeId'),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.backgroundCard,
                    backgroundImage: storeAvatarUrl.isNotEmpty
                        ? CachedNetworkImageProvider(storeAvatarUrl)
                        : null,
                    child: storeAvatarUrl.isEmpty
                        ? Icon(
                            Icons.storefront,
                            size: 16,
                            color: AppColors.textMuted,
                          )
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        storeName,
                        style: AppTypography.bodyMediumSemibold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        DoubleTapLikeOverlay(
          isLiked: isLiked,
          onLike: () => ref.read(likeStateProvider(postId).notifier).like(),
          child: AspectRatio(
            aspectRatio: 1,
            child: PageView(
              children: [
                for (final url in mediaUrls)
                  PinchZoomImage(
                    onZoomStart: _recordView,
                    child: CachedNetworkImage(imageUrl: url, fit: BoxFit.cover),
                  ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            IconButton(
              icon: AppIcon(
                isLiked ? 'heart_filled' : 'heart',
                color: isLiked ? Colors.red : null,
              ),
              onPressed: () =>
                  ref.read(likeStateProvider(postId).notifier).toggle(),
            ),
            Text('$likesCount'),
            IconButton(
              icon: const AppIcon('send'),
              onPressed: () => showSendToChatSheet(
                context,
                ref,
                postId: postId,
                postStoreId: storeId,
                postCaption: caption,
                postMediaUrl: mediaUrls.isNotEmpty ? mediaUrls.first : '',
              ),
            ),
            Text('${post['sentCount'] as int? ?? 0}'),
            IconButton(
              icon: const AppIcon('arrow_share'),
              onPressed: () => shareAndNotify(context, ref, postId),
            ),
            Text('${post['sharesCount'] as int? ?? 0}'),
            const SizedBox(width: 8),
            Icon(
              Icons.visibility_outlined,
              size: 18,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 2),
            Text(
              '${post['viewsCount'] as int? ?? 0}',
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.textMuted,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: AppIcon(
                isSaved ? 'bookmark_filled' : 'bookmark',
                color: AppColors.textPrimary,
              ),
              onPressed: () => toggleSaveAndNotify(context, ref, postId),
            ),
            if (isOwner)
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => showEditCaptionDialog(
                  context,
                  ref,
                  postId: postId,
                  currentCaption: caption,
                ),
              ),
            if (isOwner)
              IconButton(
                icon: const AppIcon('trash', color: AppColors.error),
                onPressed: () async {
                  final confirmed = await confirmDelete(
                    context,
                    ref,
                    title: s.deletePostTitle,
                    body: s.deletePostBody,
                  );
                  if (!confirmed) return;
                  await ref.read(postsServiceProvider).deletePost(postId);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
          ],
        ),
        if (caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(alignment: Alignment.centerLeft, child: Text(caption)),
          ),
        if (post['price'] != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${post['price']} TMT',
                style: AppTypography.bodyMediumSemibold.copyWith(
                  color: AppColors.brand,
                ),
              ),
            ),
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}
