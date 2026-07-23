import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_icon.dart';
import '../../core/l10n.dart';
import '../../core/media_cache.dart';
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

/// The ring-bar queue a story viewer was opened from — lets the viewer swipe
/// horizontally between users' story sequences instead of only ever showing
/// the one that was tapped. Falls back to a single-entry queue (see
/// StoryViewerScreen) for any entry point that doesn't have one (deep links).
class StoryViewerArgs {
  const StoryViewerArgs({required this.storeIds, required this.initialIndex});

  final List<String> storeIds;
  final int initialIndex;
}

/// Instagram-style story viewer: swiping left/right moves between different
/// users' story queues (with a 3D cube transition), while tapping the left
/// or right third of the screen steps back/forward within the current
/// user's own slides. See StoryViewerArgs for how the user queue arrives.
class StoryViewerScreen extends ConsumerStatefulWidget {
  const StoryViewerScreen({super.key, required this.storeId, this.args});

  final String storeId;
  final StoryViewerArgs? args;

  @override
  ConsumerState<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends ConsumerState<StoryViewerScreen> {
  late final List<String> _storeIds = widget.args?.storeIds ?? [widget.storeId];
  late final int _initialIndex = (widget.args?.initialIndex ?? 0).clamp(
    0,
    _storeIds.length - 1,
  );
  late final PageController _pageController = PageController(
    initialPage: _initialIndex,
  );
  late int _currentPage = _initialIndex;
  final Set<String> _precached = {};

  @override
  void initState() {
    super.initState();
    _prefetchAround(_currentPage);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Background-loads the next couple of users' story lists (and, for an
  /// image first slide, the image itself) so swiping to them plays instantly
  /// instead of popping up a loading spinner — mirrors Instagram silently
  /// downloading the first slide or two of the next few profiles in the
  /// queue while you're still watching the current one.
  void _prefetchAround(int index) {
    for (final i in [index, index + 1, index + 2]) {
      if (i < 0 || i >= _storeIds.length) continue;
      final storeId = _storeIds[i];
      if (!_precached.add(storeId)) continue;
      ref
          .read(storeStoriesProvider(storeId).future)
          .then((docs) {
            if (!mounted || docs.isEmpty) return;
            final first = docs.first.data();
            if (first['mediaType'] == 'image') {
              final url = first['mediaUrl'] as String?;
              if (url != null) {
                precacheImage(CachedNetworkImageProvider(url), context);
              }
            }
          })
          .catchError((_) {});
    }
  }

  void _goToNextStore() {
    if (_currentPage < _storeIds.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
      );
    } else {
      Navigator.of(context).pop();
    }
  }

  void _goToPrevStore() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pageController,
        itemCount: _storeIds.length,
        onPageChanged: (index) {
          setState(() => _currentPage = index);
          _prefetchAround(index);
        },
        itemBuilder: (context, index) {
          return _StoreStoryPage(
            storeId: _storeIds[index],
            isActive: index == _currentPage,
            onFinishedForward: _goToNextStore,
            onFinishedBackward: _goToPrevStore,
            onDismiss: () => Navigator.of(context).pop(),
          );
        },
      ),
    );
  }
}

/// One user's story sequence — tap left/right thirds step through this
/// user's own slides only; reaching either end defers to [onFinishedForward]
/// / [onFinishedBackward] (the outer PageView swiping to the next/previous
/// user) instead of popping the whole viewer itself.
class _StoreStoryPage extends ConsumerStatefulWidget {
  const _StoreStoryPage({
    required this.storeId,
    required this.isActive,
    required this.onFinishedForward,
    required this.onFinishedBackward,
    required this.onDismiss,
  });

  final String storeId;
  final bool isActive;
  final VoidCallback onFinishedForward;
  final VoidCallback onFinishedBackward;
  final VoidCallback onDismiss;

  @override
  ConsumerState<_StoreStoryPage> createState() => _StoreStoryPageState();
}

// TickerProviderStateMixin (not SingleTicker...) — this page disposes and
// recreates its AnimationController on every story advance, and a single
// ticker provider can flake on that create/dispose/create-again cadence
// (observed as the progress bar animating for story 0 then freezing from
// story 1 onward).
class _StoreStoryPageState extends ConsumerState<_StoreStoryPage>
    with TickerProviderStateMixin {
  int _index = 0;
  AnimationController? _controller;
  VideoPlayerController? _videoController;
  bool _markedSeen = false;
  final _replyController = TextEditingController();
  bool _sendingReply = false;
  double _dragDistance = 0;
  // Drives the swipe-down-to-dismiss spring-back — the drag itself just
  // sets _dragDistance directly (1:1 with the finger, same as the nav
  // bar's PageView), this only animates the release-without-dismissing case.
  late final AnimationController _dismissSpring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// "Seen" = watched through to the end — recorded the moment the last story
  /// in the sequence starts playing, so the ring greys out on return.
  void _maybeMarkSeen() {
    if (_markedSeen || _index != _stories.length - 1) return;
    _markedSeen = true;
    ref.read(storiesServiceProvider).markStoreSeen(widget.storeId);
  }

  bool get _isOwnStore =>
      (ref.read(storeIdsProvider).value ?? []).contains(widget.storeId);

  // Identifies one _startFor call so a slow, superseded load (user advanced
  // or backed up before it finished) can tell it's stale and bail instead of
  // hijacking the current story's controller — same idea as the video
  // controller identity check below, generalized to also cover the image
  // path, which has no controller of its own to compare against.
  Object? _loadToken;

  void _startFor(Map<String, dynamic> story, {String? storyId}) {
    if (!widget.isActive) return;
    _maybeMarkSeen();
    // Owner watching their own story shouldn't count toward "seen by N".
    if (storyId != null && !_isOwnStore) {
      ref.read(storiesServiceProvider).recordStoryView(storyId);
    }
    _controller?.dispose();
    _videoController?.dispose();
    _videoController = null;
    _controller = null;
    final loadToken = Object();
    _loadToken = loadToken;
    // The progress bar has nothing to show while _controller is null (see
    // the AnimatedBuilder below, which falls back to
    // kAlwaysDismissedAnimation) — so not creating it until the media is
    // actually ready to display is what keeps the bar from ticking through
    // a story the user can't see yet, on both branches below.

    final mediaUrl = story['mediaUrl'] as String;
    if (story['mediaType'] == 'video') {
      // Caching the file (not just streaming it) makes a revisit instant
      // from disk instead of re-downloading, and gives the same "wait for
      // it to actually be ready" gate as the image branch below.
      MediaCache.instance.getSingleFile(mediaUrl).then((file) {
        if (!mounted || _loadToken != loadToken || !widget.isActive) return;
        final vc = VideoPlayerController.file(file);
        _videoController = vc;
        vc.initialize().then((_) {
          // A slow init can complete after the user has already advanced
          // past this story — _startFor disposes vc and moves
          // _videoController on, but this closure still holds the old vc.
          // Without checking identity here, play() throws on a disposed
          // controller, and (worse) the closure would overwrite _controller
          // with an AnimationController built from the *old* video's
          // duration, hijacking the new story's progress bar.
          if (!mounted || _videoController != vc || !widget.isActive) return;
          vc.play();
          setState(() {
            _controller =
                AnimationController(vsync: this, duration: vc.value.duration)
                  ..addStatusListener(_onStatusChanged)
                  ..forward();
          });
        });
      });
    } else {
      precacheImage(CachedNetworkImageProvider(mediaUrl), context).then((_) {
        if (!mounted || _loadToken != loadToken || !widget.isActive) return;
        setState(() {
          _controller =
              AnimationController(
                  vsync: this,
                  duration: const Duration(seconds: 5),
                )
                ..addStatusListener(_onStatusChanged)
                ..forward();
        });
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
    } else {
      widget.onFinishedForward();
    }
  }

  void _prev() {
    if (_index > 0) {
      final stories = _stories;
      setState(() => _index--);
      _startFor(stories[_index].data(), storyId: stories[_index].id);
    } else {
      widget.onFinishedBackward();
    }
  }

  void _pause() {
    _controller?.stop();
    _videoController?.pause();
  }

  void _pauseForHold() {
    if (!widget.isActive) return;
    _controller?.stop();
    _videoController?.pause();
  }

  void _resumeFromHold() {
    if (!widget.isActive) return;
    // AnimationController.forward() with no `from:` continues from wherever
    // .value currently sits — exactly "resume", not "restart".
    _controller?.forward();
    _videoController?.play();
  }

  void _onDismissDragStart() {
    _dismissSpring.stop();
    _dragDistance = 0;
    _pause();
  }

  void _onDismissDragUpdate(DragUpdateDetails details) {
    // Downward only — an upward flick shouldn't drag the content past its
    // resting position.
    final next = _dragDistance + details.delta.dy;
    if (next < 0 && _dragDistance <= 0) return;
    setState(() => _dragDistance = next.clamp(0, double.infinity));
  }

  void _onDismissDragEnd(DragEndDetails details) {
    // Fast flick (velocity) or a slow deliberate drag (distance) — either
    // dismisses, matching Instagram.
    if ((details.primaryVelocity ?? 0) > 200 || _dragDistance > 80) {
      widget.onDismiss();
      return;
    }
    // Spring back to place — follows the finger while dragging, animates
    // only for this release-without-dismissing case, same feel as the nav
    // bar's PageView snapping back when a swipe doesn't clear its threshold.
    final start = _dragDistance;
    final animation = Tween<double>(
      begin: start,
      end: 0,
    ).animate(CurvedAnimation(parent: _dismissSpring, curve: Curves.easeOut));
    void listener() => setState(() => _dragDistance = animation.value);
    animation.addListener(listener);
    _dismissSpring
      ..reset()
      ..forward().whenComplete(() {
        animation.removeListener(listener);
        _resumeFromHold();
      });
  }

  @override
  void didUpdateWidget(_StoreStoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive == oldWidget.isActive) return;
    if (widget.isActive) {
      // Re-entering this user's queue starts fresh from their first slide,
      // same as Instagram — matches _prev()'s already-existing behavior of
      // handing off to the previous user rather than resuming mid-sequence.
      _index = 0;
      _markedSeen = false;
      final stories = _stories;
      if (stories.isNotEmpty) {
        _startFor(stories[_index].data(), storyId: stories[_index].id);
      }
    } else {
      _pause();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _videoController?.dispose();
    _replyController.dispose();
    _dismissSpring.dispose();
    super.dispose();
  }

  Future<void> _sendReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || _sendingReply) return;
    setState(() => _sendingReply = true);
    try {
      final role = await ref.read(appRoleProvider.future);
      final chatId = await ref
          .read(chatServiceProvider)
          .createOrGetChat(widget.storeId);
      final isAdmin = role == AppRole.admin || role == AppRole.superadmin;

      final docs = ref.read(storeStoriesProvider(widget.storeId)).value ?? [];
      final currentStory = _index < docs.length ? docs[_index] : null;
      final storyData = currentStory?.data();
      final storyMediaType = storyData?['mediaType'] as String?;
      // Video stories have no stored thumbnail, and reusing the raw video
      // URL as an "image" preview is exactly the bug that broke shared
      // reels in chat — so only tag a preview image for image stories.
      final storyMediaUrl = storyMediaType == 'image'
          ? (storyData?['mediaUrl'] as String?)
          : null;

      await ref
          .read(chatServiceProvider)
          .sendMessage(
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

    return SafeArea(
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
                if (widget.isActive &&
                    _controller == null &&
                    _videoController == null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && widget.isActive) {
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
                  onLongPressStart: (_) => _pauseForHold(),
                  onLongPressEnd: (_) => _resumeFromHold(),
                  onVerticalDragStart: (_) => _onDismissDragStart(),
                  onVerticalDragUpdate: _onDismissDragUpdate,
                  onVerticalDragEnd: _onDismissDragEnd,
                  child: Transform.translate(
                    offset: Offset(0, _dragDistance),
                    child: Opacity(
                      opacity: (1 - _dragDistance / 500).clamp(0.3, 1.0),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (story['mediaType'] == 'video')
                            (_videoController?.value.isInitialized ?? false)
                                ? FittedBox(
                                    fit: BoxFit.cover,
                                    child: SizedBox(
                                      width: _videoController!.value.size.width,
                                      height:
                                          _videoController!.value.size.height,
                                      child: VideoPlayer(_videoController!),
                                    ),
                                  )
                                : const Center(
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                    ),
                                  )
                          else if (_controller != null)
                            CachedNetworkImage(
                              imageUrl: story['mediaUrl'] as String,
                              fit: BoxFit.cover,
                            )
                          else
                            const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                              ),
                            ),
                          Positioned(
                            top: 8,
                            left: 8,
                            right: 8,
                            child: Row(
                              children: [
                                for (var i = 0; i < docs.length; i++)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 2,
                                      ),
                                      child: AnimatedBuilder(
                                        animation:
                                            _controller ??
                                            kAlwaysDismissedAnimation,
                                        builder: (context, _) =>
                                            LinearProgressIndicator(
                                              value: i < _index
                                                  ? 1
                                                  : (i == _index
                                                        ? (_controller?.value ??
                                                              0)
                                                        : 0),
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
                                  backgroundImage:
                                      (store?['avatarUrl'] as String?)
                                              ?.isNotEmpty ==
                                          true
                                      ? CachedNetworkImageProvider(
                                          store!['avatarUrl'] as String,
                                        )
                                      : null,
                                  child:
                                      (store?['avatarUrl'] as String?)
                                              ?.isNotEmpty !=
                                          true
                                      ? const Icon(
                                          Icons.storefront,
                                          size: 16,
                                          color: Colors.white,
                                        )
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
                                  _relativeTime(
                                    story['createdAt'] as Timestamp?,
                                  ),
                                  style: AppTypography.caption.copyWith(
                                    color: Colors.white70,
                                  ),
                                ),
                                if ((ref.watch(storeIdsProvider).value ?? [])
                                    .contains(widget.storeId))
                                  IconButton(
                                    icon: const AppIcon(
                                      'trash',
                                      color: Colors.white,
                                    ),
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
                                  icon: const AppIcon(
                                    'close',
                                    color: Colors.white,
                                  ),
                                  onPressed: widget.onDismiss,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
              loading: () => const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
              error: (error, stack) => Center(
                child: Text(
                  '${ref.watch(l10nProvider).failedToLoad}: $error',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          if (_isOwnStore)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Builder(
                builder: (context) {
                  final docs = storiesAsync.value ?? [];
                  final storyId = _index < docs.length ? docs[_index].id : null;
                  final count = storyId == null
                      ? 0
                      : ref.watch(storyViewCountProvider(storyId)).value ?? 0;
                  return Row(
                    children: [
                      const Icon(
                        Icons.visibility_outlined,
                        color: Colors.white70,
                        size: 20,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$count',
                        style: AppTypography.bodyMediumSemibold.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ],
                  );
                },
              ),
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
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
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
        ],
      ),
    );
  }
}
