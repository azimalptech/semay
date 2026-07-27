import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';
import '../../core/l10n.dart';
import '../../core/realtime_client.dart';
import '../../services/posts_service.dart';

/// Shared by every bookmark icon (post_card.dart, post_detail_screen.dart,
/// reel_player_view.dart) — toggles the save and confirms it with a snackbar
/// either way ("Added to saved" / "Removed from saved").
Future<void> toggleSaveAndNotify(
  BuildContext context,
  WidgetRef ref,
  String postId,
) async {
  final wasSaved = ref.read(saveStateProvider(postId));
  ref.read(saveStateProvider(postId).notifier).toggle();
  await ref.read(postsServiceProvider).toggleSave(postId, !wasSaved);
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

/// Store name/avatar for a post's header row — live via the `store:{id}`
/// realtime channel, so renaming a store shows on already-open feed cards
/// immediately (same as the old Firestore snapshot).
final storeSummaryProvider =
    StreamProvider.family<Map<String, dynamic>?, String>((ref, storeId) async* {
      if (storeId.isEmpty) {
        yield null;
        return;
      }
      final api = ref.watch(apiClientProvider);
      try {
        final json = await api.get('/stores/$storeId');
        yield json['store'] as Map<String, dynamic>?;
      } catch (_) {
        yield null;
      }
      await for (final event
          in ref.watch(realtimeClientProvider).subscribe('store:$storeId')) {
        if (event.type == RealtimeEventType.snapshot ||
            event.type == RealtimeEventType.upsert) {
          yield event.data as Map<String, dynamic>?;
        }
      }
    }, isAutoDispose: true);

/// Live post doc — subscribes to `post:{id}`, whose events carry the
/// aggregate counters (likes/saves/views/sent/shares). The initial REST fetch
/// also carries the full post incl. `likedByMe`/`savedByMe` (which the WS
/// counter events deliberately omit — a private flag has no cross-device
/// live value; see docs/07_MIGRATION.md Phase 9). LikeNotifier/SaveNotifier
/// seed their optimistic state from that first fetch's flags.
final postDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((
  ref,
  postId,
) async* {
  final api = ref.watch(apiClientProvider);
  Map<String, dynamic>? current;
  try {
    final json = await api.get('/posts/$postId');
    final post = json['post'] as Map<String, dynamic>?;
    current = post != null ? normalizePost(post) : null;
    yield current;
  } catch (_) {
    yield null;
  }
  await for (final event
      in ref.watch(realtimeClientProvider).subscribe('post:$postId')) {
    if (event.type == RealtimeEventType.snapshot ||
        event.type == RealtimeEventType.upsert) {
      // The channel event carries only counts + id — merge onto the last full
      // doc so caption/media/likedByMe survive across counter updates.
      final counts = event.data as Map<String, dynamic>?;
      if (counts != null) {
        current = {...?current, ...counts};
        yield current;
      }
    }
  }
}, isAutoDispose: true);

/// "Did I like this post" — seeded from the post doc's `likedByMe` flag and
/// then tracked optimistically (the like/unlike write is fire-and-forget; the
/// server is authoritative but there's no per-user live channel for it). Null
/// until the post doc first loads.
class _MyFlagNotifier extends Notifier<bool> {
  _MyFlagNotifier(this.flagKey, this.postId);

  final String flagKey; // "likedByMe" | "savedByMe"
  final String postId;
  bool? _optimistic;

  @override
  bool build() {
    final server = ref.watch(postDocProvider(postId)).value?[flagKey] as bool?;
    // Once the server value catches up to what we predicted, drop the
    // override so future server truth (e.g. another device) wins.
    if (_optimistic != null && server != null && _optimistic == server) {
      _optimistic = null;
    }
    return _optimistic ?? server ?? false;
  }

  void toggle() {
    _optimistic = !state;
    state = _optimistic!;
  }
}

final isLikedProvider = NotifierProvider.family<_MyFlagNotifier, bool, String>(
  (postId) => _MyFlagNotifier('likedByMe', postId),
  isAutoDispose: true,
);

/// Save state as a simple toggle notifier (parallels isLikedProvider).
final saveStateProvider = NotifierProvider.family<_MyFlagNotifier, bool, String>(
  (postId) => _MyFlagNotifier('savedByMe', postId),
  isAutoDispose: true,
);

/// Back-compat alias — screens still read `isSavedProvider(postId)`.
final isSavedProvider = saveStateProvider;

class LikeState {
  const LikeState({required this.isLiked, required this.likesCount});
  final bool isLiked;
  final int likesCount;
}

/// Combines the optimistic like flag with the post doc's own `likesCount`.
/// Both the heart icon and the count update the instant you tap — the count
/// is a prediction; server ground truth (from the `post:{id}` channel's
/// likesCount) always wins once it arrives. Same instant-feedback product
/// call the Firestore version made.
class LikeNotifier extends Notifier<LikeState> {
  LikeNotifier(this.postId);

  final String postId;

  int? _countBeforeToggle;
  int _pendingDelta = 0;

  @override
  LikeState build() {
    final isLiked = ref.watch(isLikedProvider(postId));
    final serverLikesCount =
        (ref.watch(postDocProvider(postId)).value?['likesCount'] as int?) ?? 0;

    int likesCount = serverLikesCount;
    if (_countBeforeToggle != null) {
      if (serverLikesCount == _countBeforeToggle) {
        likesCount = serverLikesCount + _pendingDelta;
      } else {
        // Server count moved — trust it, drop the prediction.
        _countBeforeToggle = null;
        _pendingDelta = 0;
      }
    }
    return LikeState(isLiked: isLiked, likesCount: likesCount);
  }

  void toggle() {
    final newIsLiked = !state.isLiked;
    ref.read(isLikedProvider(postId).notifier).toggle();

    final serverLikesCount =
        ref.read(postDocProvider(postId)).value?['likesCount'] as int? ??
        state.likesCount;
    _countBeforeToggle ??= serverLikesCount;
    _pendingDelta += newIsLiked ? 1 : -1;

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
