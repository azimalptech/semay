import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/json_ext.dart';

/// Largest `position` the server accepts — `store_quick_replies.position` is a
/// 32-bit MySQL int and the route rejects anything above it as 400
/// INVALID_INPUT (server/src/quickReplies/routes.ts).
const int quickReplyMaxPosition = 2147483647;

/// The slot a new reply takes so it lists last: one past the largest position
/// already in [existing] (the server serves the list ascending by position).
/// The Add sheet used to send `DateTime.now().millisecondsSinceEpoch` here — a
/// Firestore-era `order` value ~1.79e12 that has never fit the MySQL column,
/// so every Add since the cutover was a 400. Clamped at the column max rather
/// than overflowing past it: a store that already holds a row at the cap
/// would otherwise be unable to add anything ever again.
int nextQuickReplyPosition(Iterable<JsonDoc> existing) {
  var highest = -1;
  for (final doc in existing) {
    final position = doc.data()['position'];
    if (position is int && position > highest) highest = position;
  }
  return highest >= quickReplyMaxPosition ? quickReplyMaxPosition : highest + 1;
}

class QuickRepliesService {
  QuickRepliesService(this._api);

  final ApiClient _api;

  /// A store's quick replies, ordered. One-shot fetch surfaced as a stream so
  /// existing StreamBuilder call sites (chat_thread_screen, quick_replies_
  /// screen) are unchanged; callers re-listen (or invalidate quickRepliesProvider)
  /// after a mutation to refresh — quick replies change rarely, so there's no
  /// realtime channel for them.
  Stream<List<JsonDoc>> watch(String storeId) async* {
    yield await fetch(storeId);
  }

  Future<List<JsonDoc>> fetch(String storeId) async {
    final json = await _api.get('/stores/$storeId/quick-replies');
    final list = (json['quickReplies'] as List<dynamic>? ?? const []);
    return list.map((e) => JsonDoc(e as Map<String, dynamic>)).toList();
  }

  /// [position] must be within 0..[quickReplyMaxPosition]; use
  /// [nextQuickReplyPosition] to append.
  Future<void> add(String storeId, String text, {required int position}) async {
    await _api.post(
      '/stores/$storeId/quick-replies',
      body: {'text': text, 'position': position},
    );
  }

  Future<void> update(String storeId, String replyId, String text) async {
    await _api.patch('/quick-replies/$replyId', body: {'text': text});
  }

  Future<void> delete(String storeId, String replyId) async {
    await _api.delete('/quick-replies/$replyId');
  }
}

/// Refreshable quick-replies list for the management screen (quick_replies_
/// screen watches this so add/edit/delete can `ref.invalidate` it to refetch).
final quickRepliesProvider = FutureProvider.family<List<JsonDoc>, String>((
  ref,
  storeId,
) {
  return ref.watch(quickRepliesServiceProvider).fetch(storeId);
}, isAutoDispose: true);

final quickRepliesServiceProvider = Provider<QuickRepliesService>((ref) {
  return QuickRepliesService(ref.watch(apiClientProvider));
});
