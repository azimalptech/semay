import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';

typedef NotificationRequestDoc = JsonDoc;

/// A store's own history of requested broadcast notifications, newest first —
/// status flips from "pending" once a Super Admin decides. REST +
/// pull-to-refresh (the server authorizes a store admin to list their own
/// store's requests via ?storeId=).
final myNotificationRequestsProvider =
    FutureProvider.family<List<NotificationRequestDoc>, String>((ref, storeId) async {
      final json = await ref.watch(apiClientProvider).get(
        '/notification-requests',
        query: {'storeId': storeId},
      );
      final list = (json['requests'] as List<dynamic>? ?? const []);
      return list.map((e) => NotificationRequestDoc(e as Map<String, dynamic>)).toList();
    }, isAutoDispose: true);

class NotificationRequestService {
  NotificationRequestService(this._api, this._ref);

  final ApiClient _api;
  final Ref _ref;

  Future<void> requestBroadcast({
    required String storeId,
    required String message,
  }) async {
    await _api.post('/stores/$storeId/notification-requests', body: {'message': message});
    _ref.invalidate(myNotificationRequestsProvider(storeId));
  }
}

final notificationRequestServiceProvider = Provider<NotificationRequestService>(
  (ref) => NotificationRequestService(ref.watch(apiClientProvider), ref),
);
