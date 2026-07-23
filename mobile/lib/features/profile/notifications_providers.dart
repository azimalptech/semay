import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../../services/firestore_service.dart';

typedef NotificationDoc = QueryDocumentSnapshot<Map<String, dynamic>>;

/// The signed-in user's notifications, newest first. Empty (not an error)
/// when signed out, matching the rest of the app's provider conventions.
final notificationsProvider = StreamProvider<List<NotificationDoc>>((ref) {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return Stream.value(const []);

  return ref
      .watch(firestoreProvider)
      .collection('users')
      .doc(user.uid)
      .collection('notifications')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots()
      .map((snap) => snap.docs);
});

/// Unread count for the bell icon's badge.
final unreadNotificationCountProvider = Provider<int>((ref) {
  final docs = ref.watch(notificationsProvider).value ?? const [];
  return docs.where((doc) => doc.data()['read'] != true).length;
});

class NotificationsService {
  NotificationsService(this._firestore);

  final FirebaseFirestore _firestore;

  Future<void> markAllRead(List<NotificationDoc> docs) async {
    final unread = docs.where((doc) => doc.data()['read'] != true).toList();
    if (unread.isEmpty) return;
    final batch = _firestore.batch();
    for (final doc in unread) {
      batch.update(doc.reference, {'read': true});
    }
    await batch.commit();
  }
}

final notificationsServiceProvider = Provider<NotificationsService>((ref) {
  return NotificationsService(ref.watch(firestoreProvider));
});
