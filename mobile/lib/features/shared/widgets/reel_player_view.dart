import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../../core/app_icon.dart';
import '../../../core/format.dart';
import '../../../core/interaction_buffer.dart';
import '../../../core/l10n.dart';
import '../../../core/media_cache.dart';
import '../../../core/theme.dart';
import '../../../services/auth_service.dart';
import '../../../services/chat_service.dart';
import '../../../services/posts_service.dart';
import '../post_interaction_providers.dart';
import 'confirm_delete_dialog.dart';
import 'double_tap_like_overlay.dart';
import 'edit_caption_dialog.dart';
import 'expandable_text.dart';
import 'pinch_zoom_image.dart';
import 'send_to_chat_sheet.dart';

/// Shared across every reel player instance (the Reels tab pager *and* a
/// single reel opened from a post-detail push) so mute state carries over
/// consistently, same as Instagram — sound is on by default; this toggles it.
class ReelsMutedNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
}

final reelsMutedProvider = NotifierProvider<ReelsMutedNotifier, bool>(
  ReelsMutedNotifier.new,
);

/// Full-screen reel player (Figma MyReel layout): video + mute/like/save/share
/// rail + store/caption footer. Used both as a page inside the Reels tab's
/// vertical pager and, standalone with [onClose] set, when a reel is opened
/// from the home feed's square post tile — that used to open the cramped
/// square PostDetailScreen layout with icons still positioned for a square
/// card; this makes both entry points render identically.
class ReelPlayerView extends ConsumerStatefulWidget {
  const ReelPlayerView({
    super.key,
    required this.postId,
    required this.post,
    required this.isActive,
    this.onClose,
    this.initialPosition,
  });

  final String postId;
  final Map<String, dynamic> post;
  final bool isActive;
  final VoidCallback? onClose;
  // Set when opened from a reel already mid-playback elsewhere (the feed's
  // in-place autoplay tile) so this full-screen player picks up from the
  // same frame instead of restarting at 0. Null for every other entry point
  // (the Reels tab's own pager, a fresh reel just scrolled to).
  final Duration? initialPosition;

  @override
  ConsumerState<ReelPlayerView> createState() => _ReelPlayerViewState();
}

class _ReelPlayerViewState extends ConsumerState<ReelPlayerView> {
  VideoPlayerController? _video;
  // While the scrub bar is being dragged, playback is paused — used to keep
  // the scrub bar's own pause/resume distinct from a user-initiated pause.
  bool _scrubbing = false;
  bool _wasPlayingBeforeHold = false;
  bool _isFastForwarding = false;
  final _replyController = TextEditingController();
  bool _sendingReply = false;

  // A reel has no separate "small inline card vs. full detail view" split
  // the way an image post does (Home's feed tile vs. PostDetailScreen) —
  // it's already full-screen everywhere it appears, dedicated Reels tab
  // included — so "detail view only" for view-counting purposes means
  // "this reel is the active/playing one", tracked via widget.isActive
  // rather than a fixed screen. Same 2s-dwell-or-liked-or-zoomed signal as
  // ImagePostDetailContent otherwise.
  Timer? _viewTimer;
  bool _viewRecorded = false;

  @override
  void initState() {
    super.initState();
    final url = (widget.post['mediaUrls'] as List<dynamic>? ?? [])
        .cast<String>()
        .firstOrNull;
    if (url != null) _loadVideo(url);
    if (widget.isActive) _startViewTimer();
  }

  void _startViewTimer() {
    _viewTimer?.cancel();
    if (_viewRecorded) return;
    _viewTimer = Timer(const Duration(seconds: 2), _recordView);
  }

  void _recordView() {
    _viewTimer?.cancel();
    if (_viewRecorded) return;
    _viewRecorded = true;
    ref.read(postsServiceProvider).recordView(widget.postId);
  }

  // Caching the file (not just streaming it via .networkUrl) makes a
  // rewatch instant from disk instead of re-downloading — same treatment as
  // the story viewer's video loading.
  Future<void> _loadVideo(String url) async {
    final file = await MediaCache.instance.getSingleFile(url);
    if (!mounted) return;
    final vc = VideoPlayerController.file(file);
    _video = vc;
    vc.setVolume(ref.read(reelsMutedProvider) ? 0 : 1);
    // Loops indefinitely — user controls when it stops (navigating away,
    // holding to pause), not a fixed replay count.
    vc.setLooping(true);
    await vc.initialize();
    if (!mounted || _video != vc) return;
    final initialPosition = widget.initialPosition;
    debugPrint(
      'reel_player_view: postId=${widget.postId} '
      'widget.initialPosition=$initialPosition',
    );
    if (initialPosition != null && initialPosition > Duration.zero) {
      await vc.seekTo(initialPosition);
      debugPrint(
        'reel_player_view: postId=${widget.postId} seeked to $initialPosition',
      );
      if (!mounted || _video != vc) return;
    }
    if (widget.isActive) vc.play();
    setState(() {});
  }

  void _restart() {
    final video = _video;
    if (video == null) return;
    video.seekTo(Duration.zero);
    video.play();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant ReelPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _startViewTimer();
    } else if (!widget.isActive && oldWidget.isActive) {
      _viewTimer?.cancel();
    }
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    if (widget.isActive && !oldWidget.isActive) {
      // Scrolled back into view: fresh watch from the start.
      _restart();
    } else if (!widget.isActive && oldWidget.isActive) {
      video.pause();
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    _replyController.dispose();
    _viewTimer?.cancel();
    super.dispose();
  }

  Future<void> _sendReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || _sendingReply) return;
    final storeId = widget.post['storeId'] as String? ?? '';
    if (storeId.isEmpty) return;
    setState(() => _sendingReply = true);
    try {
      final role = await ref.read(appRoleProvider.future);
      final isAdmin = role == AppRole.admin || role == AppRole.superadmin;
      final chatId = await ref
          .read(chatServiceProvider)
          .createOrGetChat(storeId);
      final thumbnailUrl = widget.post['thumbnailUrl'] as String? ?? '';
      final mediaUrls = (widget.post['mediaUrls'] as List<dynamic>? ?? [])
          .cast<String>();
      await ref
          .read(chatServiceProvider)
          .sendMessage(
            chatId,
            text,
            senderRole: isAdmin ? 'admin' : 'user',
            sharedPostId: widget.postId,
            mediaUrl: thumbnailUrl.isNotEmpty
                ? thumbnailUrl
                : mediaUrls.firstOrNull,
          );
      _replyController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ref.read(l10nProvider).messageSent)),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingReply = false);
    }
  }

  // Two distinct press-and-hold zones, same as real Instagram Reels:
  // holding the left/right edges speeds playback up to 2x (release back to
  // 1x); holding the middle third pauses instead (release resumes) — the
  // same pause-on-hold behavior Stories uses.
  bool _holdIsEdge = false;

  void _onHoldStart(LongPressStartDetails details) {
    final width = MediaQuery.of(context).size.width;
    final dx = details.globalPosition.dx;
    _holdIsEdge = dx < width / 3 || dx > width * 2 / 3;
    if (_holdIsEdge) {
      _startFastForward();
    } else {
      _startPause();
    }
  }

  void _onHoldEnd() {
    if (_holdIsEdge) {
      _endFastForward();
    } else {
      _endPause();
    }
  }

  void _startFastForward() {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    _wasPlayingBeforeHold = video.value.isPlaying;
    if (_wasPlayingBeforeHold) {
      video.setPlaybackSpeed(2.0);
      setState(() => _isFastForwarding = true);
    }
  }

  void _endFastForward() {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    if (_wasPlayingBeforeHold) {
      video.setPlaybackSpeed(1.0);
      setState(() => _isFastForwarding = false);
    }
  }

  void _startPause() {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    _wasPlayingBeforeHold = video.value.isPlaying;
    if (_wasPlayingBeforeHold) {
      video.pause();
      setState(() {});
    }
  }

  void _endPause() {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    if (_wasPlayingBeforeHold) {
      video.play();
      setState(() {});
    }
  }

  void _togglePlay() {
    // The video is the main "outside the keyboard" tap target down here —
    // dismiss an open reply-field keyboard the same way tapping away from it
    // would anywhere else, rather than leaving it covering the screen.
    FocusManager.instance.primaryFocus?.unfocus();
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    video.value.isPlaying ? video.pause() : video.play();
    setState(() {});
  }

  void _onScrubStart() {
    _video?.pause();
    setState(() => _scrubbing = true);
  }

  void _onScrubSeek(double ratio) {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    final duration = video.value.duration;
    video.seekTo(duration * ratio.clamp(0.0, 1.0));
  }

  void _onScrubEnd() {
    setState(() => _scrubbing = false);
    _video?.play();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final storeId = widget.post['storeId'] as String? ?? '';
    final caption = widget.post['caption'] as String? ?? '';
    final store = ref.watch(storeSummaryProvider(storeId)).value;
    final likeState = ref.watch(likeStateProvider(widget.postId));
    final isLiked = likeState.isLiked;
    final isSaved = ref.watch(isSavedProvider(widget.postId));
    final likesCount = likeState.likesCount;
    final pending =
        ref.watch(pendingInteractionsProvider(widget.postId)).value ??
        (views: 0, sent: 0, shares: 0);
    final sentCount = (widget.post['sentCount'] as int? ?? 0) + pending.sent;
    final sharesCount = (widget.post['sharesCount'] as int? ?? 0) + pending.shares;
    final viewsCount = (widget.post['viewsCount'] as int? ?? 0) + pending.views;
    final role = ref.watch(appRoleProvider).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    final isOwner =
        (role == AppRole.admin || role == AppRole.superadmin) &&
        storeIds.contains(storeId);

    final muted = ref.watch(reelsMutedProvider);
    ref.listen<bool>(reelsMutedProvider, (_, isMuted) {
      _video?.setVolume(isMuted ? 0 : 1);
    });
    ref.listen(likeStateProvider(widget.postId), (previous, next) {
      if (next.isLiked && (previous == null || !previous.isLiked)) {
        _recordView();
      }
    });

    final topInset = MediaQuery.of(context).padding.top;

    return Column(
      children: [
        Expanded(
          child: DoubleTapLikeOverlay(
            isLiked: isLiked,
            onLike: () =>
                ref.read(likeStateProvider(widget.postId).notifier).like(),
            onSingleTap: _togglePlay,
            onHoldStart: _onHoldStart,
            onHoldEnd: _onHoldEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_video?.value.isInitialized ?? false)
                  PinchZoomImage(
                    onZoomStart: _recordView,
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
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                if (_video != null &&
                    _video!.value.isInitialized &&
                    !_video!.value.isPlaying)
                  const Center(
                    child: Icon(
                      Icons.play_arrow,
                      color: Colors.white70,
                      size: 72,
                    ),
                  ),
                if (_isFastForwarding)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.fast_forward,
                            color: Colors.white,
                            size: 20,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '2x',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (widget.onClose != null)
                  Positioned(
                    top: topInset + 8,
                    left: 8,
                    child: IconButton(
                      icon: const AppIcon('arrow_left', color: Colors.white),
                      onPressed: widget.onClose,
                    ),
                  ),
                if (isOwner)
                  Positioned(
                    top: topInset + 8,
                    right: 12,
                    child: GestureDetector(
                      onTap: () async {
                        final confirmed = await confirmDelete(
                          context,
                          ref,
                          title: s.deletePostTitle,
                          body: s.deletePostBody,
                        );
                        if (confirmed) {
                          await ref
                              .read(postsServiceProvider)
                              .deletePost(widget.postId);
                          if (context.mounted) widget.onClose?.call();
                        }
                      },
                      child: const CircleAvatar(
                        radius: 18,
                        backgroundColor: AppColors.error,
                        child: AppIcon('trash', color: Colors.white, size: 20),
                      ),
                    ),
                  ),
                if (isOwner)
                  Positioned(
                    top: topInset + 56,
                    right: 12,
                    child: GestureDetector(
                      onTap: () => showEditCaptionDialog(
                        context,
                        ref,
                        postId: widget.postId,
                        currentCaption: caption,
                      ),
                      child: const CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.black38,
                        child: Icon(
                          Icons.edit_outlined,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                // Mute toggle — kept top-side so the footer stays exactly the
                // Figma layout (which has no mute glyph); stacks under
                // delete/edit when the owner is viewing.
                Positioned(
                  top: topInset + (isOwner ? 104 : 8),
                  right: 12,
                  child: GestureDetector(
                    onTap: () => ref.read(reelsMutedProvider.notifier).toggle(),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.black38,
                      child: Icon(
                        muted ? Icons.volume_off : Icons.volume_up,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ),
                // Instagram-style right-edge icon rail — like/send/bookmark/
                // share/views stacked vertically along the right side,
                // instead of inline with the store row (which used to
                // squeeze them into one crowded horizontal line).
                Positioned(
                  right: 12,
                  bottom: 108,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _RailAction(
                        iconName: isLiked ? 'heart_filled' : 'heart',
                        color: isLiked ? AppColors.error : Colors.white,
                        label: likesCount > 0 ? formatCount(likesCount) : null,
                        onTap: () => ref
                            .read(likeStateProvider(widget.postId).notifier)
                            .toggle(),
                      ),
                      const SizedBox(height: 20),
                      _RailAction(
                        iconName: 'send',
                        color: Colors.white,
                        label: sentCount > 0 ? formatCount(sentCount) : null,
                        onTap: () => showSendToChatSheet(
                          context,
                          ref,
                          postId: widget.postId,
                          postStoreId: storeId,
                          postCaption: caption,
                          postMediaUrl:
                              widget.post['thumbnailUrl'] as String? ?? '',
                        ),
                      ),
                      const SizedBox(height: 20),
                      _RailAction(
                        iconName: isSaved ? 'bookmark_filled' : 'bookmark',
                        color: Colors.white,
                        onTap: () =>
                            toggleSaveAndNotify(context, ref, widget.postId),
                      ),
                      const SizedBox(height: 20),
                      _RailAction(
                        iconName: 'arrow_share',
                        color: Colors.white,
                        label: sharesCount > 0 ? formatCount(sharesCount) : null,
                        onTap: () =>
                            shareAndNotify(context, ref, widget.postId),
                      ),
                      const SizedBox(height: 20),
                      _RailAction(
                        icon: Icons.visibility_outlined,
                        color: Colors.white,
                        label: viewsCount > 0 ? formatCount(viewsCount) : null,
                      ),
                    ],
                  ),
                ),
                // Store row + caption — left-anchored, capped short of the
                // icon rail so long captions wrap/ellipsize instead of
                // running underneath it.
                Positioned(
                  left: 16,
                  right: 88,
                  bottom: 24,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () => context.push('/store/$storeId'),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: Colors.white,
                              backgroundImage:
                                  (store?['avatarUrl'] as String? ?? '')
                                      .isNotEmpty
                                  ? CachedNetworkImageProvider(
                                      store!['avatarUrl'] as String,
                                    )
                                  : null,
                              child:
                                  (store?['avatarUrl'] as String? ?? '').isEmpty
                                  ? Icon(
                                      Icons.storefront,
                                      size: 16,
                                      color: AppColors.textMuted,
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 140),
                              child: Text(
                                store?['name'] as String? ?? '',
                                style: AppTypography.bodyMediumSemibold
                                    .copyWith(color: Colors.white),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (caption.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ExpandableText(
                          text: caption,
                          style: AppTypography.bodySmall.copyWith(
                            color: Colors.white,
                          ),
                          moreStyle: AppTypography.bodySmall.copyWith(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      if (widget.post['price'] != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${widget.post['price']} TMT',
                          style: AppTypography.bodyMediumSemibold.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_video != null && _video!.value.isInitialized)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _ScrubBar(
                      video: _video!,
                      scrubbing: _scrubbing,
                      onScrubStart: _onScrubStart,
                      onScrubSeek: _onScrubSeek,
                      onScrubEnd: _onScrubEnd,
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Message box — sends straight to the reel's store, same pattern as
        // the story viewer's reply box. A real Column sibling below the
        // video (not a Positioned overlay) so the keyboard pushes it up
        // properly instead of covering it.
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _replyController,
                    style: const TextStyle(color: Colors.white),
                    cursorColor: Colors.white,
                    decoration: InputDecoration(
                      hintText: s.typeMessage,
                      hintStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.15),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    // Keyboard's Done key only dismisses the keyboard — it
                    // isn't a second send button. Sending is exclusively the
                    // explicit send icon below.
                    onSubmitted: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: _sendingReply
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send, color: Colors.white),
                  onPressed: _sendingReply ? null : _sendReply,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Bottom scrub bar: thin filled track showing playback progress, tap/drag
/// anywhere on it to seek. Expands slightly and shows a playhead handle
/// while actively being dragged, matching Instagram's own scrubber; pauses
/// on grab and resumes playback the moment the finger lifts.
class _ScrubBar extends StatefulWidget {
  const _ScrubBar({
    required this.video,
    required this.scrubbing,
    required this.onScrubStart,
    required this.onScrubSeek,
    required this.onScrubEnd,
  });

  final VideoPlayerController video;
  final bool scrubbing;
  final VoidCallback onScrubStart;
  final ValueChanged<double> onScrubSeek;
  final VoidCallback onScrubEnd;

  @override
  State<_ScrubBar> createState() => _ScrubBarState();
}

class _ScrubBarState extends State<_ScrubBar> {
  double? _dragRatio;

  double _ratioFor(double localX, double width) {
    if (width <= 0) return 0;
    return (localX / width).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final ratio = _ratioFor(details.localPosition.dx, width);
            setState(() => _dragRatio = ratio);
            widget.onScrubStart();
            widget.onScrubSeek(ratio);
          },
          onTapUp: (_) {
            setState(() => _dragRatio = null);
            widget.onScrubEnd();
          },
          // A touch that starts here but resolves as a vertical swipe (the
          // reels pager's own gesture) cancels the tap — without this,
          // onScrubStart's pause() never gets a matching onScrubEnd(), so
          // the reel stays paused and _onVideoTick's completion detection
          // (gated on !_scrubbing) stays dead for that reel indefinitely.
          onTapCancel: () {
            setState(() => _dragRatio = null);
            widget.onScrubEnd();
          },
          onHorizontalDragStart: (details) {
            final ratio = _ratioFor(details.localPosition.dx, width);
            setState(() => _dragRatio = ratio);
            widget.onScrubStart();
            widget.onScrubSeek(ratio);
          },
          onHorizontalDragUpdate: (details) {
            final ratio = _ratioFor(details.localPosition.dx, width);
            setState(() => _dragRatio = ratio);
            widget.onScrubSeek(ratio);
          },
          onHorizontalDragEnd: (_) {
            setState(() => _dragRatio = null);
            widget.onScrubEnd();
          },
          child: Container(
            // Larger invisible hit area than the visible bar, so it's easy
            // to grab without needing to land exactly on a thin line.
            padding: const EdgeInsets.symmetric(vertical: 10),
            color: Colors.transparent,
            child: AnimatedBuilder(
              animation: widget.video,
              builder: (context, _) {
                final duration = widget.video.value.duration;
                final position = widget.video.value.position;
                final liveRatio = duration.inMilliseconds > 0
                    ? (position.inMilliseconds / duration.inMilliseconds).clamp(
                        0.0,
                        1.0,
                      )
                    : 0.0;
                final ratio = _dragRatio ?? liveRatio;

                return AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  height: widget.scrubbing ? 5 : 2.5,
                  width: double.infinity,
                  decoration: BoxDecoration(color: Colors.white24),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      FractionallySizedBox(
                        widthFactor: ratio,
                        child: Container(color: Colors.white),
                      ),
                      if (widget.scrubbing)
                        Positioned(
                          left: (ratio * width - 6).clamp(0.0, width - 12),
                          top: -4.5,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// One entry in the right-edge icon rail (Instagram Reels layout) — icon
/// centered above its count, not beside it, so a stack of these reads as a
/// single vertical column hugging the screen edge instead of a wide row.
/// Takes either [iconName] (this app's own SVG set) or [icon] (a Material
/// fallback, for the eye/"views" glyph, which has no SVG asset).
class _RailAction extends StatelessWidget {
  const _RailAction({
    this.iconName,
    this.icon,
    required this.color,
    this.label,
    this.onTap,
  }) : assert(
         (iconName == null) != (icon == null),
         'exactly one of iconName/icon',
       );

  final String? iconName;
  final IconData? icon;
  final Color color;
  final String? label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconName != null
              ? AppIcon(iconName!, color: color, size: 28)
              : Icon(icon, color: color, size: 28),
          if (label != null) ...[
            const SizedBox(height: 4),
            Text(
              label!,
              style: AppTypography.bodySmall.copyWith(color: Colors.white),
            ),
          ],
        ],
      ),
    );
  }
}
