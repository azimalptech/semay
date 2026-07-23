import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../services/auth_service.dart';
import '../../services/firestore_service.dart';
import '../../services/posts_service.dart';

/// Shared by every bookmark icon (post_card.dart, post_detail_screen.dart,
/// reel_player_view.dart) — toggles the save and confirms it with a snackbar
/// either way ("Added to saved" / "Removed from saved").
Future<void> toggleSaveAndNotify(
  BuildContext context,
  WidgetRef ref,
  String postId,
) async {
  final wasSaved = ref.read(isSavedProvider(postId)).value ?? false;
  await ref.read(postsServiceProvider).toggleSave(postId);
  if (!context.mounted) return;
  final s = ref.read(l10nProvider);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(wasSaved ? s.removedFromSaved : s.addedToSaved)),
  );
}

/// Shared by every "share" icon — see PostsService.shareAndRecord; only
/// shows the confirmation when the OS share sheet actually completed.
Future<void> shareAndNotify(
  BuildContext context,
  WidgetRef ref,
  String postId,
) async {
  final shared = await ref.read(postsServiceProvider).shareAndRecord(postId);
  if (!shared || !context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(ref.read(l10nProvider).postShared)));
}

/// Store name/avatar for a post's header row — live, not a one-time fetch,
/// so renaming a store (or changing its avatar) shows up on already-open
/// feed cards immediately instead of needing an app restart.
final storeSummaryProvider =
    StreamProvider.family<Map<String, dynamic>?, String>((ref, storeId) {
      if (storeId.isEmpty) return Stream.value(null);
      return ref
          .watch(firestoreProvider)
          .collection('stores')
          .doc(storeId)
          .snapshots()
          .map((snap) => snap.data());
    }, isAutoDispose: true);

final postDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((
  ref,
  postId,
) {
  return ref
      .watch(firestoreProvider)
      .collection('posts')
      .doc(postId)
      .snapshots()
      .map((snap) => snap.data());
}, isAutoDispose: true);

final isLikedProvider = StreamProvider.family<bool, String>((ref, postId) {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return Stream.value(false);

  return ref
      .watch(firestoreProvider)
      .collection('posts')
      .doc(postId)
      .collection('likes')
      .doc(user.uid)
      .snapshots()
      .map((snap) => snap.exists);
}, isAutoDispose: true);

final isSavedProvider = StreamProvider.family<bool, String>((ref, postId) {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return Stream.value(false);

  return ref
      .watch(firestoreProvider)
      .collection('users')
      .doc(user.uid)
      .collection('saved')
      .doc(postId)
      .snapshots()
      .map((snap) => snap.exists);
}, isAutoDispose: true);

class LikeState {
  const LikeState({required this.isLiked, required this.likesCount});
  final bool isLiked;
  final int likesCount;
}

/// Combines [isLikedProvider] with the post doc's own `likesCount`. Both the
/// heart *icon* and the *count* update the instant you tap — the count is a
/// prediction (server ground truth, from posts/{postId}.likesCount, is
/// server-authoritative via onLikeWrite's FieldValue.increment — see
/// backend/functions/src/posts/onLikeWrite.ts — and always wins once it
/// actually arrives), not a wait-for-the-trigger value. Explicit product
/// call: instant feedback matters more here than the small chance of a
/// brief self-correcting flicker under rapid repeated tapping before the
/// trigger round-trip lands (a single deliberate tap never glitches — the
/// predicted and server-confirmed values always agree in that case).
class LikeNotifier extends Notifier<LikeState> {
  LikeNotifier(this.postId);

  final String postId;

  bool? _optimisticIsLiked;

  // The server's likesCount as of the most recent toggle(), and the net
  // predicted change since then — kept separate from _optimisticIsLiked's
  // own clearing (which fires near-instantly, off the *like doc's* fast
  // local-write echo) because the *count* only actually updates once
  // onLikeWrite's server round trip lands, which is slower; clearing the
  // count prediction on the same fast signal would flash back to the
  // stale server count for a moment before jumping to the real new one.
  int? _countBeforeToggle;
  int _pendingDelta = 0;

  @override
  LikeState build() {
    final serverIsLiked = ref.watch(isLikedProvider(postId)).value ?? false;
    final serverLikesCount =
        (ref.watch(postDocProvider(postId)).value?['likesCount'] as int?) ?? 0;

    // Dropped as soon as the like doc's own existence (not the count)
    // catches up to what was predicted — that's the write this client
    // itself made, and it echoes back near-instantly from Firestore's local
    // cache, well before the count's server round trip completes.
    if (_optimisticIsLiked != null && _optimisticIsLiked == serverIsLiked) {
      _optimisticIsLiked = null;
    }

    int likesCount = serverLikesCount;
    if (_countBeforeToggle != null) {
      if (serverLikesCount == _countBeforeToggle) {
        // The trigger this prediction was waiting on hasn't landed yet —
        // keep showing the predicted value.
        likesCount = serverLikesCount + _pendingDelta;
      } else {
        // Server count actually moved — trust it and drop the prediction,
        // whether or not it landed on exactly what was predicted (a rapid
        // toggle burst can have more than one trigger still in flight; this
        // is the "brief self-correcting flicker" edge case noted above).
        _countBeforeToggle = null;
        _pendingDelta = 0;
      }
    }

    final isLiked = _optimisticIsLiked ?? serverIsLiked;
    return LikeState(isLiked: isLiked, likesCount: likesCount);
  }

  void toggle() {
    final newIsLiked = !state.isLiked;
    _optimisticIsLiked = newIsLiked;

    // Anchor the prediction to the server's own last-known count — not the
    // currently-*displayed* one — since that's the base onLikeWrite's
    // trigger will actually increment/decrement from. Only captured once
    // per pending burst (??=): a second toggle before the first trigger
    // lands adjusts the same prediction instead of re-anchoring to what is
    // still a stale server read, which would double-count instead of
    // correctly cancelling out (like then unlike should net back to zero).
    final serverLikesCount =
        ref.read(postDocProvider(postId)).value?['likesCount'] as int? ??
        state.likesCount;
    _countBeforeToggle ??= serverLikesCount;
    _pendingDelta += newIsLiked ? 1 : -1;

    state = LikeState(
      isLiked: newIsLiked,
      likesCount: _countBeforeToggle! + _pendingDelta,
    );
    ref.read(postsServiceProvider).toggleLike(postId, newIsLiked);
  }

  /// Double-tap-to-like only ever likes, never unlikes (see
  /// DoubleTapLikeOverlay) — a no-op if already liked.
  void like() {
    if (state.isLiked) return;
    toggle();
  }
}

final likeStateProvider =
    NotifierProvider.family<LikeNotifier, LikeState, String>(
      (postId) => LikeNotifier(postId),
      isAutoDispose: true,
    );
