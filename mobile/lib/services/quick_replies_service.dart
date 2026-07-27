import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/json_ext.dart';

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

  Future<void> add(String storeId, String text, int order) async {
    await _api.post('/stores/$storeId/quick-replies', body: {'text': text, 'position': order});
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
