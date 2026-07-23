import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/chat_service.dart' show functionsProvider;
import '../../services/firestore_service.dart';

typedef NotificationRequestDoc = QueryDocumentSnapshot<Map<String, dynamic>>;

/// A store's own history of requested broadcast notifications, newest
/// first — status flips from "pending" once a Super Admin decides (see
/// decideNotificationRequest.ts).
final myNotificationRequestsProvider =
    StreamProvider.family<List<NotificationRequestDoc>, String>((ref, storeId) {
      return ref
          .watch(firestoreProvider)
          .collection('notificationRequests')
          .where('storeId', isEqualTo: storeId)
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map((snap) => snap.docs);
    }, isAutoDispose: true);

class NotificationRequestService {
  NotificationRequestService(this._functions);

  final FirebaseFunctions _functions;

  Future<void> requestBroadcast({
    required String storeId,
    required String message,
  }) async {
    await _functions.httpsCallable('requestBroadcastNotification').call({
      'storeId': storeId,
      'message': message,
    });
  }
}

final notificationRequestServiceProvider = Provider<NotificationRequestService>(
  (ref) => NotificationRequestService(ref.watch(functionsProvider)),
);
