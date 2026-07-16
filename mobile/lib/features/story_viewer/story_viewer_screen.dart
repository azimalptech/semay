import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';
import '../../services/stories_service.dart';
import '../shared/widgets/confirm_delete_dialog.dart';
import '../store_profile/store_profile_providers.dart';
import 'story_providers.dart';

String _relativeTime(Timestamp? timestamp) {
  if (timestamp == null) return '';
  final diff = DateTime.now().difference(timestamp.toDate());
  if (diff.inMinutes < 1) return 'now';
  if (diff.inHours < 1) return '${diff.inMinutes}m';
  if (diff.inDays < 1) return '${diff.inHours}h';
  return '${diff.inDays}d';
}

/// Full-screen viewer over one store's active story sequence, with a
/// per-story segmented progress bar (renamed constructor field from the
/// original `storyId` -> `storeId`: the route always identified a store's
/// story sequence, not a single story — see docs/04_SCREENS_AND_NAVIGATION.md).
class StoryViewerScreen extends ConsumerStatefulWidget {
  const StoryViewerScreen({super.key, required this.storeId});

  final String storeId;

  @override
  ConsumerState<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

// TickerProviderStateMixin (not SingleTicker...) — this screen disposes and
// recreates its AnimationController on every story advance, and a single
// ticker provider can flake on that create/dispose/create-again cadence
// (observed as the progress bar animating for story 0 then freezing from
// story 1 onward).
class _StoryViewerScreenState extends ConsumerState<StoryViewerScreen>
    with TickerProviderStateMixin {
  int _index = 0;
  AnimationController? _controller;
  VideoPlayerController? _videoController;
  bool _markedSeen = false;
  final _replyController = TextEditingController();
  bool _sendingReply = false;
  double _dragDistance = 0;

  /// "Seen" = watched through to the end — recorded the moment the last story
  /// in the sequence starts playing, so the ring greys out on return.
  void _maybeMarkSeen() {
    if (_markedSeen || _index != _stories.length - 1) return;
    _markedSeen = true;
    ref.read(storiesServiceProvider).markStoreSeen(widget.storeId);
  }

  bool get _isOwnStore =>
      (ref.read(storeIdsProvider).value ?? []).contains(widget.storeId);

  void _startFor(Map<String, dynamic> story, {String? storyId}) {
    _maybeMarkSeen();
    // Owner watching their own story shouldn't count toward "seen by N".
    if (storyId != null && !_isOwnStore) {
      ref.read(storiesServiceProvider).recordStoryView(storyId);
    }
    _controller?.dispose();
    _videoController?.dispose();
    _videoController = null;
    _controller = null;

    if (story['mediaType'] == 'video') {
      final vc = VideoPlayerController.networkUrl(Uri.parse(story['mediaUrl'] as String));
      _videoController = vc;
      vc.initialize().then((_) {
        if (!mounted) return;
        vc.play();
        setState(() {
          _controller = AnimationController(vsync: this, duration: vc.value.duration)
            ..addStatusListener(_onStatusChanged)
            ..forward();
        });
      });
    } else {
      setState(() {
        _controller = AnimationController(vsync: this, duration: const Duration(seconds: 5))
          ..addStatusListener(_onStatusChanged)
          ..forward();
      });
    }
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed) _next();
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _stories =>
      ref.read(storeStoriesProvider(widget.storeId)).value ?? [];

  void _next() {
    final stories = _stories;
    if (_index < stories.length - 1) {
      setState(() => _index++);
      _startFor(stories[_index].data(), storyId: stories[_index].id);
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _prev() {
    if (_index > 0) {
      final stories = _stories;
      setState(() => _index--);
      _startFor(stories[_index].data(), storyId: stories[_index].id);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _videoController?.dispose();
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _sendReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || _sendingReply) return;
    setState(() => _sendingReply = true);
    try {
      final role = await ref.read(appRoleProvider.future);
      final chatId = await ref.read(chatServiceProvider).createOrGetChat(widget.storeId);
      final isAdmin = role == AppRole.admin || role == AppRole.superadmin;

      final docs = ref.read(storeStoriesProvider(widget.storeId)).value ?? [];
      final currentStory = _index < docs.length ? docs[_index] : null;
      final storyData = currentStory?.data();
      final storyMediaType = storyData?['mediaType'] as String?;
      // Video stories have no stored thumbnail, and reusing the raw video
      // URL as an "image" preview is exactly the bug that broke shared
      // reels in chat — so only tag a preview image for image stories.
      final storyMediaUrl =
          storyMediaType == 'image' ? (storyData?['mediaUrl'] as String?) : null;

      await ref.read(chatServiceProvider).sendMessage(
            chatId,
            text,
            senderRole: isAdmin ? 'admin' : 'user',
            sharedStoryId: currentStory?.id,
            mediaUrl: storyMediaUrl,
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

  @override
  Widget build(BuildContext context) {
    final storiesAsync = ref.watch(storeStoriesProvider(widget.storeId));
    final store = ref.watch(storeDocProvider(widget.storeId)).value;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: storiesAsync.when(
                data: (docs) {
                  if (docs.isEmpty) {
                    return Center(
                      child: Text(
                        ref.watch(l10nProvider).noActiveStories,
                        style: const TextStyle(color: Colors.white),
                      ),
                    );
                  }
                  if (_index >= docs.length) _index = docs.length - 1;
                  if (_controller == null && _videoController == null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _startFor(docs[_index].data(), storyId: docs[_index].id);
                      }
                    });
                  }
                  final story = docs[_index].data();

                  return GestureDetector(
                    onTapUp: (details) {
                      final width = MediaQuery.of(context).size.width;
                      if (details.globalPosition.dx < width / 3) {
                        _prev();
                      } else {
                        _next();
                      }
                    },
                    onVerticalDragStart: (_) => _dragDistance = 0,
                    onVerticalDragUpdate: (details) => _dragDistance += details.delta.dy,
                    onVerticalDragEnd: (details) {
                      // Fast flick (velocity) or a slow deliberate drag
                      // (distance) — either dismisses, matching Instagram.
                      if ((details.primaryVelocity ?? 0) > 200 || _dragDistance > 80) {
                        Navigator.of(context).pop();
                      }
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (story['mediaType'] == 'video')
                          (_videoController?.value.isInitialized ?? false)
                              ? FittedBox(
                                  fit: BoxFit.cover,
                                  child: SizedBox(
                                    width: _videoController!.value.size.width,
                                    height: _videoController!.value.size.height,
                                    child: VideoPlayer(_videoController!),
                                  ),
                                )
                              : const Center(child: CircularProgressIndicator(color: Colors.white))
                        else
                          CachedNetworkImage(imageUrl: story['mediaUrl'] as String, fit: BoxFit.cover),
                        Positioned(
                          top: 8,
                          left: 8,
                          right: 8,
                          child: Row(
                            children: [
                              for (var i = 0; i < docs.length; i++)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 2),
                                    child: AnimatedBuilder(
                                      animation: _controller ?? kAlwaysDismissedAnimation,
                                      builder: (context, _) => LinearProgressIndicator(
                                        value: i < _index
                                            ? 1
                                            : (i == _index ? (_controller?.value ?? 0) : 0),
                                        backgroundColor: Colors.white24,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Positioned(
                          top: 20,
                          left: 12,
                          right: 12,
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: Colors.white24,
                                backgroundImage: (store?['avatarUrl'] as String?)?.isNotEmpty == true
                                    ? CachedNetworkImageProvider(store!['avatarUrl'] as String)
                                    : null,
                                child: (store?['avatarUrl'] as String?)?.isNotEmpty != true
                                    ? const Icon(Icons.storefront, size: 16, color: Colors.white)
                                    : null,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  store?['name'] as String? ?? '',
                                  style: AppTypography.bodyMediumSemibold
                                      .copyWith(color: Colors.white),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                _relativeTime(story['createdAt'] as Timestamp?),
                                style: AppTypography.caption.copyWith(color: Colors.white70),
                              ),
                              if ((ref.watch(storeIdsProvider).value ?? [])
                                  .contains(widget.storeId))
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.white),
                                  onPressed: () async {
                                    final s = ref.read(l10nProvider);
                                    final confirmed = await confirmDelete(
                                      context,
                                      ref,
                                      title: s.deleteStoryTitle,
                                      body: s.deleteStoryBody,
                                    );
                                    if (confirmed) {
                                      await ref
                                          .read(storiesServiceProvider)
                                          .deleteStory(docs[_index].id);
                                    }
                                  },
                                ),
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.white),
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator(color: Colors.white)),
                error: (error, stack) => Center(
                  child: Text('${ref.watch(l10nProvider).failedToLoad}: $error',
                      style: const TextStyle(color: Colors.white)),
                ),
              ),
            ),
            if (_isOwnStore)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Builder(builder: (context) {
                  final docs = storiesAsync.value ?? [];
                  final storyId = _index < docs.length ? docs[_index].id : null;
                  final count = storyId == null
                      ? 0
                      : ref.watch(storyViewCountProvider(storyId)).value ?? 0;
                  return Row(
                    children: [
                      const Icon(Icons.visibility_outlined, color: Colors.white70, size: 20),
                      const SizedBox(width: 6),
                      Text('$count',
                          style: AppTypography.bodyMediumSemibold.copyWith(color: Colors.white)),
                    ],
                  );
                }),
              )
            else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replyController,
                      style: const TextStyle(color: Colors.white),
                      cursorColor: Colors.white,
                      decoration: InputDecoration(
                        hintText: ref.watch(l10nProvider).typeMessage,
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.15),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _sendReply(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: _sendingReply
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send, color: Colors.white),
                    onPressed: _sendingReply ? null : _sendReply,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
