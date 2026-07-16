import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/l10n.dart';
import '../../services/firestore_service.dart';
import '../shared/widgets/reel_player_view.dart';

/// Reels nav tab (Figma MyReel layout, global scope): every store's reels,
/// newest first, as a full-screen vertical pager — same feed for every role.
final globalReelsProvider =
    StreamProvider<List<QueryDocumentSnapshot<Map<String, dynamic>>>>((ref) {
  return ref
      .watch(firestoreProvider)
      .collection('posts')
      .where('type', isEqualTo: 'reel')
      .orderBy('createdAt', descending: true)
      .limit(50)
      .snapshots()
      .map((snap) => snap.docs);
});

class ReelsScreen extends ConsumerStatefulWidget {
  const ReelsScreen({super.key});

  @override
  ConsumerState<ReelsScreen> createState() => _ReelsScreenState();
}

class _ReelsScreenState extends ConsumerState<ReelsScreen> {
  int _activeIndex = 0;
  // The bottom-nav tab bar sits outside this screen in an IndexedStack (see
  // _RoleScaffold in router.dart), which keeps every tab's widget tree alive
  // when you switch away — nothing in this file's own lifecycle fires just
  // because the tab is no longer showing. VisibilityDetector is what
  // actually notices, so the active reel gets paused instead of playing on
  // in the background.
  bool _tabVisible = true;

  @override
  Widget build(BuildContext context) {
    final reelsAsync = ref.watch(globalReelsProvider);
    final s = ref.watch(l10nProvider);

    return VisibilityDetector(
      key: const Key('reels-tab'),
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0;
        if (visible != _tabVisible) setState(() => _tabVisible = visible);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: reelsAsync.when(
          data: (reels) {
            if (reels.isEmpty) {
              return Center(
                child: Text(s.noReelsYet, style: const TextStyle(color: Colors.white)),
              );
            }
            if (_activeIndex >= reels.length) _activeIndex = reels.length - 1;
            return PageView.builder(
              scrollDirection: Axis.vertical,
              itemCount: reels.length,
              onPageChanged: (index) => setState(() => _activeIndex = index),
              itemBuilder: (context, index) => ReelPlayerView(
                postId: reels[index].id,
                post: reels[index].data(),
                isActive: index == _activeIndex && _tabVisible,
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator(color: Colors.white)),
          error: (error, stack) => Center(
            child: Text('${s.failedToLoad}: $error', style: const TextStyle(color: Colors.white)),
          ),
        ),
      ),
    );
  }
}
