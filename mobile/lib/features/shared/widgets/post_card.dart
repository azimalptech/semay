import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../core/app_icon.dart';
import '../../../core/theme.dart';
import '../../../services/posts_service.dart';
import '../post_interaction_providers.dart';
import 'double_tap_like_overlay.dart';
import 'pinch_zoom_image.dart';
import 'reel_player_view.dart' show reelsMutedProvider;
import 'send_to_chat_sheet.dart';

/// Post card — Figma frame 195:4299, node 195:4325 (post block).
class PostCard extends ConsumerStatefulWidget {
  const PostCard({super.key, required this.postId, required this.post});

  final String postId;
  final Map<String, dynamic> post;

  @override
  ConsumerState<PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<PostCard> {
  int _page = 0;

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
    final mediaUrls = (post['mediaUrls'] as List<dynamic>? ?? []).cast<String>();
    final thumbnailUrl = post['thumbnailUrl'] as String? ?? '';
    final caption = post['caption'] as String? ?? '';

    final store = ref.watch(storeSummaryProvider(storeId)).value;
    final storeName = store?['name'] as String? ?? '';
    final storeAvatarUrl = store?['avatarUrl'] as String? ?? '';

    final isLiked = ref.watch(isLikedProvider(postId)).value ?? false;
    final isSaved = ref.watch(isSavedProvider(postId)).value ?? false;
    final likesCount = post['likesCount'] as int? ?? 0;
    // A reel's mediaUrls[0] is a video file — sharing that as an "image"
    // preview breaks the chat bubble, so prefer the thumbnail whenever one
    // exists (matches posts_grid_view.dart / liked_screen.dart).
    final previewImageUrl = type == 'reel' && thumbnailUrl.isNotEmpty
        ? thumbnailUrl
        : (mediaUrls.isNotEmpty ? mediaUrls.first : '');

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.borderDivider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: GestureDetector(
              onTap: () => context.push('/store/$storeId'),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.backgroundCard,
                    backgroundImage:
                        storeAvatarUrl.isNotEmpty ? CachedNetworkImageProvider(storeAvatarUrl) : null,
                    child: storeAvatarUrl.isEmpty
                        ? const Icon(Icons.storefront, size: 16, color: AppColors.textMuted)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(storeName, style: AppTypography.bodyMediumSemibold)),
                  IconButton(
                    icon: isSaved
                        ? const Icon(Icons.bookmark, color: Colors.black)
                        : const AppIcon('bookmark', color: AppColors.textPrimary),
                    onPressed: () => ref.read(postsServiceProvider).toggleSave(postId),
                  ),
                ],
              ),
            ),
          ),
          DoubleTapLikeOverlay(
            isLiked: isLiked,
            onLike: () => ref.read(postsServiceProvider).toggleLike(postId),
            onSingleTap: type == 'reel' ? () => context.push('/post/$postId') : null,
            child: AspectRatio(
              aspectRatio: 1,
              child: _PostMedia(
                postId: postId,
                type: type,
                mediaUrls: mediaUrls,
                thumbnailUrl: thumbnailUrl,
                page: _page,
                onPageChanged: (i) => setState(() => _page = i),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Figma 195:4335: carousel page dots sit centered between the
                // action icons, not on the image itself.
                if (mediaUrls.length > 1)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < mediaUrls.length; i++)
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i == _page ? AppColors.brand : AppColors.buttonMuted,
                          ),
                        ),
                    ],
                  ),
                Row(
                  children: [
                    InkWell(
                      onTap: () => ref.read(postsServiceProvider).toggleLike(postId),
                      child: Row(
                        children: [
                          isLiked
                              ? const AppIcon('heart', size: 24, color: AppColors.error)
                              : const Icon(Icons.favorite_border,
                                  size: 24, color: AppColors.textPrimary),
                          const SizedBox(width: 4),
                          Text('$likesCount', style: AppTypography.bodySmall),
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
                      child: const AppIcon('send_to_chat', size: 24, color: AppColors.textPrimary),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () => SharePlus.instance
                          .share(ShareParams(uri: Uri.parse('semay://post/$postId'))),
                      child: const AppIcon('arrow_share', size: 24, color: AppColors.textPrimary),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text.rich(
                TextSpan(
                  style: AppTypography.bodyMedium,
                  children: [
                    TextSpan(text: '$storeName ', style: AppTypography.bodyMediumSemibold),
                    TextSpan(text: caption),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              _formatDate(post['createdAt']),
              style: AppTypography.bodySmall.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDate(dynamic timestamp) {
  final date = timestamp?.toDate();
  if (date == null) return '';
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${date.day} ${months[date.month - 1]}, $hour:$minute';
}

class _PostMedia extends StatelessWidget {
  const _PostMedia({
    required this.postId,
    required this.type,
    required this.mediaUrls,
    required this.thumbnailUrl,
    required this.page,
    required this.onPageChanged,
  });

  final String postId;
  final String type;
  final List<String> mediaUrls;
  final String thumbnailUrl;
  final int page;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    if (mediaUrls.isEmpty) return Container(color: AppColors.borderDivider);

    if (type == 'reel') {
      return _FeedReelPlayer(
        postId: postId,
        videoUrl: mediaUrls.first,
        thumbnailUrl: thumbnailUrl.isNotEmpty ? thumbnailUrl : mediaUrls.first,
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
            child: CachedNetworkImage(imageUrl: mediaUrls[i], fit: BoxFit.cover),
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
                  style: AppTypography.bodySmall.copyWith(color: AppColors.textOnPrimary),
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
  const _FeedReelPlayer({required this.postId, required this.videoUrl, required this.thumbnailUrl});

  final String postId;
  final String videoUrl;
  final String thumbnailUrl;

  @override
  ConsumerState<_FeedReelPlayer> createState() => _FeedReelPlayerState();
}

class _FeedReelPlayerState extends ConsumerState<_FeedReelPlayer> {
  VideoPlayerController? _video;
  bool _visible = false;
  // Plays twice (first play + one repeat) then stops on a replay icon,
  // same as the dedicated Reels tab / post-detail player.
  int _replays = 0;
  bool _ended = false;
  // Brief flash of the mute/unmute icon on tap — a transient confirmation
  // instead of a persistent always-visible badge sitting on the video.
  bool _showMuteFlash = false;
  Timer? _muteFlashTimer;

  @override
  void initState() {
    super.initState();
    final vc = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    _video = vc;
    vc.setVolume(ref.read(reelsMutedProvider) ? 0 : 1);
    vc.addListener(_onVideoTick);
    vc.initialize().then((_) {
      if (!mounted) return;
      if (_visible) vc.play();
      setState(() {});
    });
  }

  void _onVideoTick() {
    final video = _video;
    if (video == null || !video.value.isInitialized || _ended) return;
    final duration = video.value.duration;
    if (duration <= Duration.zero) return;
    // Android's reported end-of-playback position is reliably a few ms
    // short of duration, never >=, so an exact comparison never fires.
    final remaining = duration - video.value.position;
    final completed = !video.value.isPlaying && remaining < const Duration(milliseconds: 300);
    if (!completed) return;
    if (_replays < 1) {
      _replays++;
      video.seekTo(Duration.zero);
      video.play();
    } else if (mounted) {
      setState(() => _ended = true);
    }
  }

  @override
  void dispose() {
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    _muteFlashTimer?.cancel();
    super.dispose();
  }

  void _toggleMute() {
    ref.read(reelsMutedProvider.notifier).toggle();
    _muteFlashTimer?.cancel();
    setState(() => _showMuteFlash = true);
    _muteFlashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _showMuteFlash = false);
    });
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    final isVisible = info.visibleFraction > 0.6;
    if (isVisible == _visible) return;
    _visible = isVisible;
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    if (isVisible) {
      // Scrolled back into view: fresh watch, fresh loop budget.
      _replays = 0;
      _ended = false;
      video.seekTo(Duration.zero);
      video.play();
    } else {
      video.pause();
    }
  }

  void _replay() {
    final video = _video;
    if (video == null) return;
    _replays = 0;
    _ended = false;
    video.seekTo(Duration.zero);
    video.play();
    setState(() {});
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
      child: GestureDetector(
        onTap: _ended ? _replay : _toggleMute,
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            if (_video?.value.isInitialized ?? false)
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: _video!.value.size.width,
                  height: _video!.value.size.height,
                  child: VideoPlayer(_video!),
                ),
              )
            else
              CachedNetworkImage(imageUrl: widget.thumbnailUrl, fit: BoxFit.cover),
            if (_ended)
              const Icon(Icons.refresh, color: Colors.white70, size: 56),
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: _showMuteFlash ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: CircleAvatar(
                  radius: 22,
                  backgroundColor: Colors.black45,
                  child: Icon(muted ? Icons.volume_off : Icons.volume_up,
                      color: Colors.white, size: 22),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
