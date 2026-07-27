import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/api_client.dart';
import '../../core/l10n.dart';
import '../feed/feed_providers.dart';
import '../shared/widgets/reel_player_view.dart';

/// Reels nav tab (Figma MyReel layout, global scope): every store's reels,
/// newest first, as a full-screen vertical pager — same feed for every role.
/// REST fetch + pull-to-refresh (the RefreshIndicator below invalidates this);
/// no realtime list-channel for the global reels feed, matching the home feed.
final globalReelsProvider = FutureProvider<List<PostDoc>>((ref) async {
  final json = await ref.read(apiClientProvider).get('/reels', query: {'limit': 50});
  return postsFromResponse(json);
});

class ReelsScreen extends ConsumerStatefulWidget {
  const ReelsScreen({super.key, required this.onExitToHome});

  /// Bottom nav bar is hidden on this tab (see _SwipeableTabShell) and its
  /// own PageView already owns horizontal drags for the scrub bar, so it
  /// can't be swiped away like the other tabs — this back arrow, wired to
  /// jump the shell's PageController back to Home, is the only way out.
  final VoidCallback onExitToHome;

  @override
  ConsumerState<ReelsScreen> createState() => _ReelsScreenState();
}

class _ReelsScreenState extends ConsumerState<ReelsScreen> {
  int _activeIndex = 0;
  // The bottom-nav tab bar sits outside this screen in a kept-alive
  // PageView page (see _SwipeableTabShell in router.dart), which keeps
  // every tab's widget tree alive when you switch away — nothing in this
  // file's own lifecycle fires just because the tab is no longer showing.
  // VisibilityDetector is what actually notices, so the active reel gets
  // paused instead of playing on in the background.
  bool _tabVisible = true;

  @override
  Widget build(BuildContext context) {
    final reelsAsync = ref.watch(globalReelsProvider);
    final s = ref.watch(l10nProvider);

    return VisibilityDetector(
      key: const Key('reels-tab'),
      onVisibilityChanged: (info) {
        // VisibilityDetector can deliver one last callback just after this
        // widget leaves the tree, arriving after dispose().
        if (!mounted) return;
        final visible = info.visibleFraction > 0;
        if (visible != _tabVisible) setState(() => _tabVisible = visible);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: reelsAsync.when(
          data: (reels) {
            if (reels.isEmpty) {
              return Center(
                child: Text(
                  s.noReelsYet,
                  style: const TextStyle(color: Colors.white),
                ),
              );
            }
            if (_activeIndex >= reels.length) _activeIndex = reels.length - 1;
            // AlwaysScrollableScrollPhysics so dragging down past the very
            // first reel (rather than being clamped) reports the overscroll
            // RefreshIndicator needs to trigger — same pull-to-refresh
            // pattern as the Home feed, without disturbing normal
            // reel-to-reel swiping anywhere else in the list.
            return RefreshIndicator(
              color: Colors.white,
              backgroundColor: Colors.black,
              onRefresh: () async => ref.invalidate(globalReelsProvider),
              child: PageView.builder(
                scrollDirection: Axis.vertical,
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: reels.length,
                onPageChanged: (index) => setState(() => _activeIndex = index),
                itemBuilder: (context, index) => ReelPlayerView(
                  postId: reels[index].id,
                  post: reels[index].data(),
                  isActive: index == _activeIndex && _tabVisible,
                  onClose: widget.onExitToHome,
                ),
              ),
            );
          },
          loading: () => const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
          error: (error, stack) => Center(
            child: Text(
              '${s.failedToLoad}: $error',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
