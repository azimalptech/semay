import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../core/l10n.dart';
import '../../../core/theme.dart';
import '../../../services/auth_service.dart';
import '../../../services/posts_service.dart';
import '../post_interaction_providers.dart';
import 'confirm_delete_dialog.dart';
import 'double_tap_like_overlay.dart';
import 'edit_caption_dialog.dart';

/// Shared across every reel player instance (the Reels tab pager *and* a
/// single reel opened from a post-detail push) so mute state carries over
/// consistently, same as Instagram — sound is on by default; this toggles it.
class ReelsMutedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final reelsMutedProvider = NotifierProvider<ReelsMutedNotifier, bool>(ReelsMutedNotifier.new);

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
  });

  final String postId;
  final Map<String, dynamic> post;
  final bool isActive;
  final VoidCallback? onClose;

  @override
  ConsumerState<ReelPlayerView> createState() => _ReelPlayerViewState();
}

class _ReelPlayerViewState extends ConsumerState<ReelPlayerView> {
  VideoPlayerController? _video;
  // Plays twice (first play + one repeat), then stops on a replay icon
  // instead of looping forever.
  int _replays = 0;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    final url = (widget.post['mediaUrls'] as List<dynamic>? ?? []).cast<String>().firstOrNull;
    if (url != null) {
      final vc = VideoPlayerController.networkUrl(Uri.parse(url));
      _video = vc;
      vc.setVolume(ref.read(reelsMutedProvider) ? 0 : 1);
      vc.addListener(_onVideoTick);
      vc.initialize().then((_) {
        if (!mounted) return;
        if (widget.isActive) vc.play();
        setState(() {});
      });
    }
  }

  void _onVideoTick() {
    final video = _video;
    if (video == null || !video.value.isInitialized || _ended) return;
    final duration = video.value.duration;
    if (duration <= Duration.zero) return;
    // Android's reported end-of-playback position is reliably a few ms
    // short of duration, never >=, so an exact comparison never fires and
    // the reel just sits paused on the last frame forever.
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

  void _restart() {
    final video = _video;
    if (video == null) return;
    _replays = 0;
    _ended = false;
    video.seekTo(Duration.zero);
    video.play();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant ReelPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    if (widget.isActive && !oldWidget.isActive) {
      // Scrolled back into view: fresh watch, fresh loop budget.
      _restart();
    } else if (!widget.isActive && oldWidget.isActive) {
      video.pause();
    }
  }

  @override
  void dispose() {
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (_ended) {
      _restart();
      return;
    }
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    video.value.isPlaying ? video.pause() : video.play();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final storeId = widget.post['storeId'] as String? ?? '';
    final caption = widget.post['caption'] as String? ?? '';
    final store = ref.watch(storeSummaryProvider(storeId)).value;
    final isLiked = ref.watch(isLikedProvider(widget.postId)).value ?? false;
    final isSaved = ref.watch(isSavedProvider(widget.postId)).value ?? false;
    final likesCount = widget.post['likesCount'] as int? ?? 0;
    final role = ref.watch(appRoleProvider).value;
    final storeIds = ref.watch(storeIdsProvider).value ?? [];
    final isOwner =
        (role == AppRole.admin || role == AppRole.superadmin) && storeIds.contains(storeId);

    final muted = ref.watch(reelsMutedProvider);
    ref.listen<bool>(reelsMutedProvider, (_, isMuted) {
      _video?.setVolume(isMuted ? 0 : 1);
    });

    final bottomInset = MediaQuery.of(context).padding.bottom;
    final topInset = MediaQuery.of(context).padding.top;

    return DoubleTapLikeOverlay(
      isLiked: isLiked,
      onLike: () => ref.read(postsServiceProvider).toggleLike(widget.postId),
      onSingleTap: _togglePlay,
      child: Stack(
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
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (_video != null && _video!.value.isInitialized && !_video!.value.isPlaying)
            Center(
              child: Icon(
                _ended ? Icons.refresh : Icons.play_arrow,
                color: Colors.white70,
                size: 72,
              ),
            ),
          if (widget.onClose != null)
            Positioned(
              top: topInset + 8,
              left: 8,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
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
                    await ref.read(postsServiceProvider).deletePost(widget.postId);
                    if (context.mounted) widget.onClose?.call();
                  }
                },
                child: const CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.error,
                  child: Icon(Icons.delete_outline, color: Colors.white, size: 20),
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
                  child: Icon(Icons.edit_outlined, color: Colors.white, size: 18),
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
                child: Icon(muted ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
          // Figma MyReel footer: store row with the heart/bookmark/share
          // actions inline on its right, caption below spanning full width.
          Positioned(
            left: 16,
            right: 16,
            bottom: 24 + bottomInset,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.white,
                      backgroundImage: (store?['avatarUrl'] as String? ?? '').isNotEmpty
                          ? CachedNetworkImageProvider(store!['avatarUrl'] as String)
                          : null,
                      child: (store?['avatarUrl'] as String? ?? '').isEmpty
                          ? const Icon(Icons.storefront, size: 16, color: AppColors.textMuted)
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        store?['name'] as String? ?? '',
                        style: AppTypography.bodyMediumSemibold.copyWith(color: Colors.white),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _FooterAction(
                      icon: isLiked ? Icons.favorite : Icons.favorite_border,
                      color: isLiked ? AppColors.error : Colors.white,
                      label: likesCount > 0 ? '$likesCount' : null,
                      onTap: () => ref.read(postsServiceProvider).toggleLike(widget.postId),
                    ),
                    const SizedBox(width: 16),
                    _FooterAction(
                      icon: isSaved ? Icons.bookmark : Icons.bookmark_border,
                      color: Colors.white,
                      onTap: () => ref.read(postsServiceProvider).toggleSave(widget.postId),
                    ),
                    const SizedBox(width: 16),
                    _FooterAction(
                      icon: Icons.share_outlined,
                      color: Colors.white,
                      onTap: () => SharePlus.instance.share(
                        ShareParams(uri: Uri.parse('semay://post/${widget.postId}')),
                      ),
                    ),
                  ],
                ),
                if (caption.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodySmall.copyWith(color: Colors.white),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterAction extends StatelessWidget {
  const _FooterAction({required this.icon, required this.color, this.label, this.onTap});

  final IconData icon;
  final Color color;
  final String? label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 24),
          if (label != null) ...[
            const SizedBox(width: 4),
            Text(label!, style: AppTypography.bodySmall.copyWith(color: Colors.white)),
          ],
        ],
      ),
    );
  }
}
