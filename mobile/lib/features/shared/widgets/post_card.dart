import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../core/app_icon.dart';
import '../../../core/format.dart';
import '../../../core/interaction_buffer.dart';
import '../../../core/json_ext.dart';
import '../../../core/l10n.dart';
import '../../../core/media_cache.dart';
import '../../../core/theme.dart';
import '../../../services/posts_service.dart';
import '../post_interaction_providers.dart';
import 'confirm_delete_dialog.dart';
import 'double_tap_like_overlay.dart';
import 'edit_caption_dialog.dart';
import 'expandable_text.dart';
import 'pinch_zoom_image.dart';
import 'reel_player_view.dart' show reelsMutedProvider;
import 'send_to_chat_sheet.dart';

/// Post card — Figma frame 195:4299, node 195:4325 (post block).
class PostCard extends ConsumerStatefulWidget {
  const PostCard({
    super.key,
    required this.postId,
    required this.post,
    this.showOwnerActions = false,
  });

  final String postId;
  final Map<String, dynamic> post;
  // Set by StorePostsPagerScreen (the store's own grid pager, which reuses
  // this same card for both images and reels) when the signed-in admin owns
  // this post's store — the public Home feed never sets this, since it mixes
  // in every store's posts, not just the current admin's own.
  final bool showOwnerActions;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  int _page = 0;
  // Written by _FeedReelPlayer as it plays, read at tap-time so opening the
  // full-screen player (PostDetailScreen -> ReelPlayerView) can resume from
  // here instead of restarting at 0 — no ValueListenableBuilder attached, so
  // this is just a cheap place to stash the latest position.
  final _reelPosition = ValueNotifier<Duration>(Duration.zero);

  @override
  void dispose() {
    _reelPosition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final postId = widget.postId;
    // The feed fetches once (not a live listener — see feed_providers.dart),
    // so widget.post is frozen at load time; overlay postDocProvider's live
    // stream so likesCount (and anything else server-mutated) stays current
    // without needing a pull-to-refresh after every like.
    final post = ref.watch(postDocProvider(postId)).value ?? widget.post;
    final type = post['type'] as String? ?? 'image';
    final storeId = post['storeId'] as String? ?? '';
    final mediaUrls = (post['mediaUrls'] as List<dynamic>? ?? [])
        .cast<String>();
    final thumbnailUrl = post['thumbnailUrl'] as String? ?? '';
    final caption = post['caption'] as String? ?? '';

    final store = ref.watch(storeSummaryProvider(storeId)).value;
    final storeName = store?['name'] as String? ?? '';
    final storeAvatarUrl = store?['avatarUrl'] as String? ?? '';

    final likeState = ref.watch(likeStateProvider(postId));
    final isLiked = likeState.isLiked;
    final isSaved = ref.watch(isSavedProvider(postId));
    final likesCount = likeState.likesCount;
    // Optimistic view/send/share: add this session's not-yet-flushed taps to the
    // server counters so a tap shows immediately (see interaction_buffer.dart).
    final pending =
        ref.watch(pendingInteractionsProvider(postId)).value ??
        (views: 0, sent: 0, shares: 0);
    final sentCount = (post['sentCount'] as int? ?? 0) + pending.sent;
    final sharesCount = (post['sharesCount'] as int? ?? 0) + pending.shares;
    final viewsCount = (post['viewsCount'] as int? ?? 0) + pending.views;
    // A reel's mediaUrls[0] is a video file — sharing that as an "image"
    // preview breaks the chat bubble, so prefer the thumbnail whenever one
    // exists (matches posts_grid_view.dart / liked_screen.dart).
    final previewImageUrl = type == 'reel' && thumbnailUrl.isNotEmpty
        ? thumbnailUrl
        : (mediaUrls.isNotEmpty ? mediaUrls.first : '');

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.borderDivider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
            child: GestureDetector(
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
                    child: Text(
                      storeName,
                      style: AppTypography.bodyMediumSemibold,
                    ),
                  ),
                  IconButton(
                    icon: AppIcon(
                      isSaved ? 'bookmark_filled' : 'bookmark',
                      color: AppColors.textPrimary,
                    ),
                    onPressed: () => toggleSaveAndNotify(context, ref, postId),
                  ),
                ],
              ),
            ),
          ),
          DoubleTapLikeOverlay(
            isLiked: isLiked,
            onLike: () => ref.read(likeStateProvider(postId).notifier).like(),
            onSingleTap: type == 'reel'
                ? () {
                    debugPrint(
                      'post_card: opening reel $postId at position '
                      '${_reelPosition.value}',
                    );
                    context.push(
                      '/post/$postId',
                      extra: _reelPosition.value.inMilliseconds,
                    );
                  }
                : null,
            child: AspectRatio(
              aspectRatio: 1,
              child: _PostMedia(
                postId: postId,
                type: type,
                mediaUrls: mediaUrls,
                thumbnailUrl: thumbnailUrl,
                page: _page,
                onPageChanged: (i) => setState(() => _page = i),
                positionNotifier: _reelPosition,
              ),
            ),
          ),
          // Carousel page dots get their own line above the action icons —
          // previously both sat in one Stack (Figma 195:4335 has the dots
          // centered "between" the icons), which visually crowded/collided
          // once the icon row grew send/share/view counts too. Separate
          // lines can never collide, at any screen width or icon-row length.
          if (mediaUrls.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: _buildCarouselDots(mediaUrls.length, _page),
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              mediaUrls.length > 1 ? 8 : 12,
              16,
              0,
            ),
            child: Row(
              children: [
                InkWell(
                  onTap: () =>
                      ref.read(likeStateProvider(postId).notifier).toggle(),
                  child: Row(
                    children: [
                      isLiked
                          ? const AppIcon(
                              'heart_filled',
                              size: 24,
                              color: AppColors.error,
                            )
                          : AppIcon(
                              'heart',
                              size: 24,
                              color: AppColors.textPrimary,
                            ),
                      const SizedBox(width: 4),
                      Text(formatCount(likesCount), style: AppTypography.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                InkWell(
                  onTap: () => showSendToChatSheet(
                    context,
                    ref,
                    postId: postId,
                    postStoreId: storeId,
                    postCaption: caption,
                    postMediaUrl: previewImageUrl,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(
                        'send_to_chat',
                        size: 24,
                        color: AppColors.textPrimary,
                      ),
                      if (sentCount > 0) ...[
                        const SizedBox(width: 4),
                        Text(
                          formatCount(sentCount),
                          style: AppTypography.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                InkWell(
                  onTap: () => shareAndNotify(context, ref, postId),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(
                        'arrow_share',
                        size: 24,
                        color: AppColors.textPrimary,
                      ),
                      if (sharesCount > 0) ...[
                        const SizedBox(width: 4),
                        Text(
                          formatCount(sharesCount),
                          style: AppTypography.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Icon(
                  Icons.visibility_outlined,
                  size: 24,
                  color: AppColors.textMuted,
                ),
                if (viewsCount > 0) ...[
                  const SizedBox(width: 4),
                  Text(
                    formatCount(viewsCount),
                    style: AppTypography.bodySmall.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
                const Spacer(),
                if (widget.showOwnerActions) ...[
                  const SizedBox(width: 16),
                  InkWell(
                    onTap: () => showEditCaptionDialog(
                      context,
                      ref,
                      postId: postId,
                      currentCaption: caption,
                    ),
                    child: Icon(
                      Icons.edit_outlined,
                      size: 24,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  InkWell(
                    onTap: () async {
                      final s = ref.read(l10nProvider);
                      final confirmed = await confirmDelete(
                        context,
                        ref,
                        title: s.deletePostTitle,
                        body: s.deletePostBody,
                      );
                      if (!confirmed) return;
                      await ref.read(postsServiceProvider).deletePost(postId);
                    },
                    child: const AppIcon(
                      'trash',
                      size: 24,
                      color: AppColors.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: ExpandableText(
                prefix: storeName,
                prefixStyle: AppTypography.bodyMediumSemibold,
                text: caption,
                style: AppTypography.bodyMedium,
              ),
            ),
          if (post['price'] != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                '${post['price']} TMT',
                style: AppTypography.bodyMediumSemibold.copyWith(
                  color: AppColors.brand,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              _formatDate(post['createdAt']),
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDate(dynamic timestamp) {
  // createdAt is now an ISO-8601 string from the REST API (was a Firestore
  // Timestamp with .toDate()) — parseTimestamp handles the string safely.
  final date = parseTimestamp(timestamp);
  if (date == null) return '';
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${date.day} ${months[date.month - 1]}, $hour:$minute';
}

/// Instagram's carousel dot indicator: at most 5 dots, in a window that
/// slides to keep the active page roughly centered. Whichever edge of the
/// window doesn't reach the actual first/last item shrinks to a tiny dot,
/// signaling "more that way" without needing a dot per item (which would
/// overflow the row for a 10-photo carousel). At <=5 items, every dot is
/// shown at full size — there's nothing to hide.
List<Widget> _buildCarouselDots(int count, int page) {
  const windowSize = 5;
  final windowStart = count <= windowSize
      ? 0
      : (page - 2).clamp(0, count - windowSize);
  final windowEnd = count <= windowSize ? count : windowStart + windowSize;

  return [
    for (var i = windowStart; i < windowEnd; i++)
      _CarouselDot(
        // Tiny only at a window edge that isn't *also* the real first/last
        // item — once the window has slid all the way to one end, that
        // end's dot is a genuine (possibly active) item, not a "more" hint.
        tiny:
            (i == windowStart && windowStart > 0) ||
            (i == windowEnd - 1 && windowEnd < count),
        active: i == page,
      ),
  ];
}

class _CarouselDot extends StatelessWidget {
  const _CarouselDot({required this.tiny, required this.active});

  final bool tiny;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final size = tiny ? 4.0 : 6.0;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? AppColors.brand : AppColors.buttonMuted,
      ),
    );
  }
}

class _PostMedia extends StatelessWidget {
  const _PostMedia({
    required this.postId,
    required this.type,
    required this.mediaUrls,
    required this.thumbnailUrl,
    required this.page,
    required this.onPageChanged,
    required this.positionNotifier,
  });

  final String postId;
  final String type;
  final List<String> mediaUrls;
  final String thumbnailUrl;
  final int page;
  final ValueChanged<int> onPageChanged;
  final ValueNotifier<Duration> positionNotifier;

  @override
  Widget build(BuildContext context) {
    if (mediaUrls.isEmpty) return Container(color: AppColors.borderDivider);

    if (type == 'reel') {
      return _FeedReelPlayer(
        postId: postId,
        videoUrl: mediaUrls.first,
        thumbnailUrl: thumbnailUrl.isNotEmpty ? thumbnailUrl : mediaUrls.first,
        positionNotifier: positionNotifier,
      );
    }

    if (mediaUrls.length == 1) {
      return PinchZoomImage(
        child: CachedNetworkImage(imageUrl: mediaUrls.first, fit: BoxFit.cover),
      );
    }

    return Stack(
      children: [
        PageView.builder(
          itemCount: mediaUrls.length,
          onPageChanged: onPageChanged,
          itemBuilder: (context, i) => PinchZoomImage(
            child: CachedNetworkImage(
              imageUrl: mediaUrls[i],
              fit: BoxFit.cover,
            ),
          ),
        ),
        Positioned(
          top: 12,
          right: 12,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.overlayAlphaBlack,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${page + 1}/${mediaUrls.length}',
                  style: AppTypography.bodySmall.copyWith(
                    color: AppColors.textOnPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// In-feed reel autoplay: plays only while >=60% of the tile is on-screen
/// (VisibilityDetector), muted/unmuted following the same shared toggle as
/// the dedicated Reels tab so the setting is consistent app-wide.
class _FeedReelPlayer extends ConsumerStatefulWidget {
  const _FeedReelPlayer({
    required this.postId,
    required this.videoUrl,
    required this.thumbnailUrl,
    required this.positionNotifier,
  });

  final String postId;
  final String videoUrl;
  final String thumbnailUrl;
  final ValueNotifier<Duration> positionNotifier;

  @override
  ConsumerState<_FeedReelPlayer> createState() => _FeedReelPlayerState();
}

class _FeedReelPlayerState extends ConsumerState<_FeedReelPlayer> {
  VideoPlayerController? _video;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _loadVideo();
  }

  // Caching the file (not just streaming it via .networkUrl) makes a
  // rewatch instant from disk instead of re-downloading — same treatment as
  // the story viewer's video loading.
  Future<void> _loadVideo() async {
    final file = await MediaCache.instance.getSingleFile(widget.videoUrl);
    if (!mounted) return;
    final vc = VideoPlayerController.file(file);
    _video = vc;
    vc.setVolume(ref.read(reelsMutedProvider) ? 0 : 1);
    // Loops indefinitely — user controls when it stops (scrolling away),
    // not a fixed replay count.
    vc.setLooping(true);
    vc.addListener(_reportPosition);
    await vc.initialize();
    if (!mounted || _video != vc) return;
    if (_visible) vc.play();
    setState(() {});
  }

  // Keeps the parent PostCard's positionNotifier current so tapping through
  // to the full-screen player (see PostCard's onSingleTap) can resume from
  // here instead of restarting at 0 — video_player's listener already fires
  // on every position update during playback, cheap to just mirror it.
  void _reportPosition() {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    widget.positionNotifier.value = video.value.position;
  }

  @override
  void dispose() {
    _video?.removeListener(_reportPosition);
    _video?.dispose();
    super.dispose();
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    // VisibilityDetector can deliver one last callback just after this
    // widget leaves the tree (e.g. a pull-to-refresh removing this card),
    // arriving after dispose() — _video isn't nulled out there, so without
    // this guard a disposed controller's pause()/play() gets called and
    // throws.
    if (!mounted) return;
    final isVisible = info.visibleFraction > 0.6;
    if (isVisible == _visible) return;
    _visible = isVisible;
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    if (isVisible) {
      // Scrolled back into view: fresh watch from the start.
      video.seekTo(Duration.zero);
      video.play();
    } else {
      video.pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = ref.watch(reelsMutedProvider);
    ref.listen<bool>(reelsMutedProvider, (_, isMuted) {
      _video?.setVolume(isMuted ? 0 : 1);
    });

    return VisibilityDetector(
      key: Key('feed-reel-${widget.postId}'),
      onVisibilityChanged: _onVisibilityChanged,
      // No onTap on the video area itself — it needs to fall through to the
      // outer DoubleTapLikeOverlay's onSingleTap, which opens the reel in
      // the full-screen player. An earlier attempt at tap-to-mute here stole
      // that tap instead.
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          if (_video?.value.isInitialized ?? false)
            PinchZoomImage(
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: _video!.value.size.width,
                  height: _video!.value.size.height,
                  child: VideoPlayer(_video!),
                ),
              ),
            )
          else
            CachedNetworkImage(
              imageUrl: widget.thumbnailUrl,
              fit: BoxFit.cover,
            ),
          // Small, corner-scoped hit area — deliberately not covering the
          // whole tile, so it can't compete with the outer open-reel tap.
          Positioned(
            right: 8,
            bottom: 8,
            child: GestureDetector(
              onTap: () => ref.read(reelsMutedProvider.notifier).toggle(),
              child: CircleAvatar(
                radius: 14,
                backgroundColor: AppColors.overlayAlphaBlack,
                child: Icon(
                  muted ? Icons.volume_off : Icons.volume_up,
                  color: Colors.white,
                  size: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
