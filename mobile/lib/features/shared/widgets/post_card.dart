import 'dart:io';
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
import '../../../core/shell_tab.dart';
import '../../../core/theme.dart';
import '../../../services/posts_service.dart';
import '../post_interaction_providers.dart';
import '../view_dwell.dart';
import 'confirm_delete_dialog.dart';
import 'double_tap_like_overlay.dart';
import 'edit_caption_dialog.dart';
import 'expandable_text.dart';
import 'pinch_zoom_image.dart';
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
  // True while more than 60% of the media square is on screen — the one
  // visibility signal for this card, shared by the view dwell below and
  // the inline reel's autoplay (_FeedReelPlayer listens to it).
  final _mediaVisible = ValueNotifier<bool>(false);
  // A card counts as viewed after ViewDwell.threshold on screen, in the feed
  // just like in the detail view — scrolling past used to never count (an
  // earlier product decision, since reversed). InteractionBuffer's
  // 30-minute window still keeps a re-scrolled card from counting twice.
  late ViewDwell _viewDwell;

  @override
  void initState() {
    super.initState();
    _viewDwell = _newViewDwell();
  }

  ViewDwell _newViewDwell() => ViewDwell(
    () => ref.read(postsServiceProvider).recordView(widget.postId),
    inForeground: ref.read(appInForegroundProvider),
  );

  @override
  void didUpdateWidget(PostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The feed keys its cards by post id; the store's and search's pagers
    // build by index, so a refresh there can hand this State a different
    // post. That post gets a dwell of its own — this one may already have
    // recorded, and the detector (keyed per State) reports no change for a
    // tile that stayed put — and no stale reel position for the tap-through.
    if (oldWidget.postId == widget.postId) return;
    _viewDwell.cancel();
    _viewDwell = _newViewDwell();
    if (_mediaVisible.value) _viewDwell.start();
    _reelPosition.value = Duration.zero;
  }

  @override
  void dispose() {
    _viewDwell.cancel();
    _mediaVisible.dispose();
    _reelPosition.dispose();
    super.dispose();
  }

  void _onMediaVisibilityChanged(VisibilityInfo info) {
    // VisibilityDetector can deliver one last callback just after this
    // widget leaves the tree (e.g. a pull-to-refresh removing this card),
    // arriving after dispose().
    if (!mounted) return;
    final visible = info.visibleFraction > 0.6;
    if (visible == _mediaVisible.value) return;
    _mediaVisible.value = visible;
    if (visible) {
      _viewDwell.start();
    } else {
      _viewDwell.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final postId = widget.postId;
    ref.listen<bool>(appInForegroundProvider, (_, inForeground) {
      _viewDwell.inForeground = inForeground;
    });
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
    // No sharesCount here: the design's share control carries no count (Figma
    // 426:6054), unlike like/send/view. Shares are still recorded server-side
    // and surface in the store's own stats.
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
          // Figma 426:6025 — the store identity, the carousel counter and the
          // page dots all sit ON the image, not in rows above/below it. The
          // image is square (393x393 on a 393pt frame), expressed as an
          // AspectRatio so it holds on any screen width rather than pinning a
          // literal 393px that would be wrong on every other device.
          // One detector per card, on the media square, feeding both the view
          // dwell and (for a reel) the inline player. Keyed per instance, not
          // per post: the same post can be on screen twice at once (Home feed
          // under a pushed StorePostsPagerScreen), and visibility_detector
          // keeps its bookkeeping per key.
          VisibilityDetector(
            key: ObjectKey(this),
            onVisibilityChanged: _onMediaVisibilityChanged,
            child: DoubleTapLikeOverlay(
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
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _PostMedia(
                        postId: postId,
                        type: type,
                        mediaUrls: mediaUrls,
                        thumbnailUrl: thumbnailUrl,
                        page: _page,
                        onPageChanged: (i) => setState(() => _page = i),
                        visible: _mediaVisible,
                        positionNotifier: _reelPosition,
                      ),
                    ),
                    // 426:6026 — pt 12, pb 16, px 12, name pill left / counter right.
                    Positioned(
                      top: 12,
                      left: 12,
                      right: 12,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onTap: () => context.push('/store/$storeId'),
                            child: _StorePill(
                              name: storeName,
                              avatarUrl: storeAvatarUrl,
                            ),
                          ),
                          const Spacer(),
                          if (mediaUrls.length > 1)
                            _GlassBadge(
                              borderRadius: 16,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Text(
                                '${_page + 1}/${mediaUrls.length}',
                                style: AppTypography.bodySmall.copyWith(
                                  color: AppColors.textOnPrimary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    // 426:6033 — dots sit at y=367 of the 393pt image, i.e. 12pt
                    // clear of the bottom edge once the 14pt pill is accounted for.
                    if (mediaUrls.length > 1)
                      Positioned(
                        bottom: 12,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: _GlassBadge(
                            borderRadius: 24,
                            padding: const EdgeInsets.all(4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: _buildCarouselDots(
                                mediaUrls.length,
                                _page,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
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
                      // 426:6049 — always shown, matching like/view. The design
                      // has no hide-when-zero state for any of the three.
                      const SizedBox(width: 4),
                      Text(
                        formatCount(sentCount),
                        style: AppTypography.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Figma 426:6050 — the view count is a first-class stat in the
                // row, same 24pt icon and primary-coloured 13pt count as like
                // and send, using Figma's own exported eye glyph rather than a
                // Material stand-in. Always shown (the design has no zero
                // state), unlike the old muted-grey conditional treatment.
                AppIcon('eye', size: 24, color: AppColors.textPrimary),
                const SizedBox(width: 4),
                Text(formatCount(viewsCount), style: AppTypography.bodySmall),
                const Spacer(),
                // 426:6053 — bookmark moved here from the old header row above
                // the image, which no longer exists.
                InkWell(
                  onTap: () => toggleSaveAndNotify(context, ref, postId),
                  child: AppIcon(
                    isSaved ? 'bookmark_filled' : 'bookmark',
                    size: 24,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 16),
                // 426:6054 — share is the last item, and carries no count in
                // the design (unlike like/send/view). Builder: the sheet is
                // anchored to this icon's own box (see shareAndNotify).
                Builder(
                  builder: (shareContext) => InkWell(
                    onTap: () => shareAndNotify(
                      shareContext,
                      ref,
                      postId,
                      isReel: type == 'reel',
                      storeName: storeName,
                      caption: caption,
                    ),
                    child: AppIcon(
                      'arrow_share',
                      size: 24,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                // Not in the Figma card, which only draws the customer state.
                // Kept for the post's own store admin so they retain a way to
                // edit/delete from the feed (owner's decision).
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
/// The translucent, blurred chip the design uses for everything overlaid on a
/// post image — the store pill, the "1/8" counter and the dot strip.
///
/// Figma calls this background/alpha-black (rgba(0,0,0,0.4)) with a 6px
/// backdrop blur. The blur is what keeps white text legible over a bright
/// photo, so it's part of the design rather than decoration; ClipRRect is
/// required because BackdropFilter would otherwise blur the whole layer.
class _GlassBadge extends StatelessWidget {
  const _GlassBadge({
    required this.child,
    required this.borderRadius,
    required this.padding,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          padding: padding,
          color: AppColors.overlayAlphaBlack,
          child: child,
        ),
      ),
    );
  }
}

/// Store avatar + name overlaid on the top-left of a post image (Figma
/// 426:6027). Note the name is Body/Small REGULAR in white here — not the
/// semibold treatment it has in the caption below the image.
class _StorePill extends StatelessWidget {
  const _StorePill({required this.name, required this.avatarUrl});

  final String name;
  final String avatarUrl;

  @override
  Widget build(BuildContext context) {
    return _GlassBadge(
      borderRadius: 50,
      // Asymmetric by design: 4 on the avatar side, 12 after the text.
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: AppColors.backgroundCard,
            backgroundImage: avatarUrl.isNotEmpty
                ? CachedNetworkImageProvider(avatarUrl)
                : null,
            child: avatarUrl.isEmpty
                ? Icon(Icons.storefront, size: 12, color: AppColors.textMuted)
                : null,
          ),
          const SizedBox(width: 4),
          Text(
            name,
            style: AppTypography.bodySmall.copyWith(
              color: AppColors.textOnPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

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
    required this.visible,
    required this.positionNotifier,
  });

  final String postId;
  final String type;
  final List<String> mediaUrls;
  final String thumbnailUrl;
  final int page;
  final ValueChanged<int> onPageChanged;
  final ValueNotifier<bool> visible;
  final ValueNotifier<Duration> positionNotifier;

  @override
  Widget build(BuildContext context) {
    if (mediaUrls.isEmpty) return Container(color: AppColors.borderDivider);

    if (type == 'reel') {
      // No fallback to mediaUrls.first here: for a reel that is the .mp4
      // itself, and handing it to CachedNetworkImage as a poster just paints
      // a broken-image frame until the video initialises. Most reels arrive
      // with thumbnailUrl '' (the web composer has no thumbnail generator),
      // and the feed now serves reels constantly, so the player draws its own
      // dark poster for that case instead.
      return _FeedReelPlayer(
        postId: postId,
        videoUrl: mediaUrls.first,
        thumbnailUrl: thumbnailUrl,
        visible: visible,
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

/// In-feed reel autoplay — the square tile a reel row from GET /feed renders
/// as, sitting between photo posts in date order with the same store pill,
/// action row and caption as any other card. Plays only while >=60% of the
/// tile is on-screen ([visible], from PostCard's VisibilityDetector), the
/// tab it sits in is the settled one and the app is in the foreground —
/// muted, every time, with the corner speaker unmuting this one tile only:
/// following the Reels tab's shared toggle meant one unmute there turned
/// every card's autoplay loud for the rest of the session. Tapping the tile
/// falls through to PostCard's onSingleTap, which opens the full-screen reel
/// player at this reel, resuming from [positionNotifier].
class _FeedReelPlayer extends ConsumerStatefulWidget {
  const _FeedReelPlayer({
    required this.postId,
    required this.videoUrl,
    required this.thumbnailUrl,
    required this.visible,
    required this.positionNotifier,
  });

  final String postId;
  final String videoUrl;
  final String thumbnailUrl;
  final ValueNotifier<bool> visible;
  final ValueNotifier<Duration> positionNotifier;

  @override
  ConsumerState<_FeedReelPlayer> createState() => _FeedReelPlayerState();
}

class _FeedReelPlayerState extends ConsumerState<_FeedReelPlayer> {
  VideoPlayerController? _video;
  // Set once the file fetch is under way, so the many _syncPlayback
  // triggers (scroll, tab settle, foreground) start it exactly once.
  Future<void>? _load;
  // Which shell tab this card sits in, or null outside the shell (the
  // store's and search's post pagers are pushed routes) — there only scroll
  // visibility and app foreground gate playback.
  int? _shellTab;
  bool _muted = true;

  @override
  void initState() {
    super.initState();
    widget.visible.addListener(_onVisibleChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shellTab = ShellTabScope.maybeIndexOf(context);
  }

  @override
  void didUpdateWidget(_FeedReelPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      oldWidget.visible.removeListener(_onVisibleChanged);
      widget.visible.addListener(_onVisibleChanged);
    }
    // The feed keys its cards by post id, so this element normally lives
    // and dies with one reel. Belt and braces for an unkeyed host: a
    // different reel landing here must not keep the previous one's clip
    // playing under the new post's pill and caption.
    if (oldWidget.videoUrl != widget.videoUrl) {
      _dropVideo();
      _syncPlayback();
    }
  }

  // Caching the file (not just streaming it via .networkUrl) makes a
  // rewatch instant from disk instead of re-downloading — same treatment as
  // the story viewer's video loading.
  Future<void> _loadVideo() async {
    final url = widget.videoUrl;
    final File file;
    try {
      file = await MediaCache.instance.getSingleFile(url);
    } catch (_) {
      // A dead URL or a dropped connection keeps the poster; the next
      // scroll-in tries again instead of leaving this tile black for the
      // rest of the session. (Not if the host has since moved on to
      // another reel — that fetch is someone else's.)
      if (mounted && url == widget.videoUrl) _load = null;
      return;
    }
    // Stale if the host swapped reels while the fetch was in flight, or a
    // parallel fetch for the same URL (swapped away and back) already won.
    if (!mounted || _video != null || url != widget.videoUrl) return;
    final vc = VideoPlayerController.file(file);
    _video = vc;
    vc.setVolume(_muted ? 0 : 1);
    // Loops indefinitely — user controls when it stops (scrolling away),
    // not a fixed replay count.
    vc.setLooping(true);
    vc.addListener(_reportPosition);
    await vc.initialize();
    if (!mounted || _video != vc) return;
    _syncPlayback();
    setState(() {});
  }

  void _dropVideo() {
    _video?.removeListener(_reportPosition);
    _video?.dispose();
    _video = null;
    _load = null;
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
    widget.visible.removeListener(_onVisibleChanged);
    _dropVideo();
    super.dispose();
  }

  void _onVisibleChanged() {
    final video = _video;
    // Scrolled back into view: fresh watch from the start.
    if (widget.visible.value && video != null && video.value.isInitialized) {
      video.seekTo(Duration.zero);
    }
    _syncPlayback();
  }

  void _toggleMuted() {
    setState(() => _muted = !_muted);
    _video?.setVolume(_muted ? 0 : 1);
  }

  // The one rule for whether this tile plays right now; every input change
  // (scroll, shell tab settling, app foreground) funnels through here. It
  // is also what starts the file fetch — only once the tile first qualifies
  // to play, never on mount: a reel can be 100 MB, the feed's ListView
  // builds cards past the viewport, and fetching in initState pulled every
  // reel the user scrolled anywhere near, in full, on mobile data. Safe
  // before the controller initialises: _loadVideo re-runs it once the file
  // is ready, so an early "play" is never lost.
  void _syncPlayback() {
    final shouldPlay =
        widget.visible.value &&
        ref.read(appInForegroundProvider) &&
        (_shellTab == null || ref.read(settledShellTabProvider) == _shellTab);
    final video = _video;
    if (video == null) {
      if (shouldPlay) _load ??= _loadVideo();
      return;
    }
    if (!video.value.isInitialized) return;
    if (shouldPlay == video.value.isPlaying) return;
    if (shouldPlay) {
      video.play();
    } else {
      video.pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(appInForegroundProvider, (_, _) => _syncPlayback());
    ref.listen<int?>(settledShellTabProvider, (_, _) => _syncPlayback());

    // No onTap on the video area itself — it needs to fall through to the
    // outer DoubleTapLikeOverlay's onSingleTap, which opens the reel in
    // the full-screen player. An earlier attempt at tap-to-mute here stole
    // that tap instead.
    return Stack(
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
        else if (widget.thumbnailUrl.isNotEmpty)
          CachedNetworkImage(
            imageUrl: widget.thumbnailUrl,
            fit: BoxFit.cover,
            // A missing/expired thumbnail file must not show the default
            // broken-image icon in the middle of the feed — same dark
            // poster as the no-thumbnail case, the video replaces it.
            errorWidget: (_, _, _) => const ColoredBox(color: Colors.black),
          )
        else
          const ColoredBox(color: Colors.black),
        // Small, corner-scoped hit area — deliberately not covering the
        // whole tile, so it can't compete with the outer open-reel tap.
        Positioned(
          right: 8,
          bottom: 8,
          child: GestureDetector(
            onTap: _toggleMuted,
            child: CircleAvatar(
              radius: 14,
              backgroundColor: AppColors.overlayAlphaBlack,
              child: Icon(
                _muted ? Icons.volume_off : Icons.volume_up,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
