import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';
import '../../services/auth_service.dart';

typedef NotificationDoc = JsonDoc;

/// The signed-in user's notifications, newest first. Empty (not an error)
/// when signed out. REST + pull-to-refresh (no realtime channel — a new
/// notification also arrives as an FCM push, and the list refreshes on open).
final notificationsProvider = FutureProvider<List<NotificationDoc>>((ref) async {
  final session = await ref.watch(authStateChangesProvider.future);
  if (session == null) return const [];
  final json = await ref.watch(apiClientProvider).get('/notifications', query: {'limit': 100});
  final list = (json['notifications'] as List<dynamic>? ?? const []);
  return list.map((e) => NotificationDoc(e as Map<String, dynamic>)).toList();
});

/// Unread count for the bell icon's badge — `readAt == null` means unread
/// (the old boolean `read` became a nullable timestamp; see docs/02_DATA_MODEL).
final unreadNotificationCountProvider = Provider<int>((ref) {
  final docs = ref.watch(notificationsProvider).value ?? const [];
  return docs.where((doc) => doc.data()['readAt'] == null).length;
});

class NotificationsService {
  NotificationsService(this._api, this._ref);

  final ApiClient _api;
  final Ref _ref;

  Future<void> markAllRead(List<NotificationDoc> docs) async {
    final hasUnread = docs.any((doc) => doc.data()['readAt'] == null);
    if (!hasUnread) return;
    await _api.post('/notifications/read-all');
    _ref.invalidate(notificationsProvider);
  }
}

final notificationsServiceProvider = Provider<NotificationsService>((ref) {
  return NotificationsService(ref.watch(apiClientProvider), ref);
});
