import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import 'story_providers.dart';

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

class _StoryViewerScreenState extends ConsumerState<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  AnimationController? _controller;
  VideoPlayerController? _videoController;

  void _startFor(Map<String, dynamic> story) {
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

  List<Map<String, dynamic>> get _stories =>
      (ref.read(storeStoriesProvider(widget.storeId)).value ?? [])
          .map((doc) => doc.data())
          .toList();

  void _next() {
    final stories = _stories;
    if (_index < stories.length - 1) {
      setState(() => _index++);
      _startFor(stories[_index]);
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _prev() {
    if (_index > 0) {
      final stories = _stories;
      setState(() => _index--);
      _startFor(stories[_index]);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final storiesAsync = ref.watch(storeStoriesProvider(widget.storeId));

    return Scaffold(
      backgroundColor: Colors.black,
      body: storiesAsync.when(
        data: (docs) {
          if (docs.isEmpty) {
            return const Center(
              child: Text('No active stories', style: TextStyle(color: Colors.white)),
            );
          }
          if (_index >= docs.length) _index = docs.length - 1;
          if (_controller == null && _videoController == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _startFor(docs[_index].data());
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
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 200) Navigator.of(context).pop();
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
                                value: i < _index ? 1 : (i == _index ? (_controller?.value ?? 0) : 0),
                                backgroundColor: Colors.white24,
                                color: Colors.white,
                              ),
                            ),
                          ),
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
          child: Text('Error: $error', style: const TextStyle(color: Colors.white)),
        ),
      ),
    );
  }
}
