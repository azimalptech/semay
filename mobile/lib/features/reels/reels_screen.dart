import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/l10n.dart';
import '../../core/shell_tab.dart';
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

  @override
  Widget build(BuildContext context) {
    final reelsAsync = ref.watch(globalReelsProvider);
    final s = ref.watch(l10nProvider);
    // This screen lives in a kept-alive PageView page (see _SwipeableTabShell
    // in router.dart), so nothing in its own lifecycle says whether the tab
    // is showing. The shell publishes that instead — false until the pager
    // has actually come to rest here, so a page built while a tab tap scrolls
    // past Reels never starts a reel behind another tab (a VisibilityDetector
    // here never reported "hidden" for that case). Passed to the player
    // apart from which reel is current: a tab coming back resumes the reel,
    // scrolling to one starts it over.
    final reelsTabSettled = ref.watch(reelsTabSettledProvider);

    return Scaffold(
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
                isActive: index == _activeIndex,
                visible: reelsTabSettled,
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
    );
  }
}
