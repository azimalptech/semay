import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';
import 'firestore_service.dart';

// firebase_options.dart is still a demo/placeholder project (see its
// REPLACE_ME values) — there is no real VAPID key to fetch a working web
// token against yet. This mirrors that same placeholder convention.
const _webVapidKey = 'REPLACE_ME_VAPID_KEY';

final messagingProvider = Provider<FirebaseMessaging>((ref) => FirebaseMessaging.instance);

class NotificationService {
  NotificationService(this._messaging, this._firestore, this._auth);

  final FirebaseMessaging _messaging;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  Future<void> initAndSyncToken() async {
    try {
      await _messaging.requestPermission();
      final token = kIsWeb
          ? await _messaging.getToken(vapidKey: _webVapidKey)
          : await _messaging.getToken();
      if (token == null) return;

      final uid = _auth.currentUser?.uid;
      if (uid == null) return;

      await _firestore.collection('users').doc(uid).update({
        'fcmTokens': FieldValue.arrayUnion([token]),
      });
    } catch (e) {
      // Expected to fail until a real Firebase project/VAPID key exists —
      // never let it block app usage.
      debugPrint('NotificationService: token sync failed (expected for now): $e');
    }
  }

  void listenForegroundMessages(void Function(RemoteMessage message) onMessage) {
    FirebaseMessaging.onMessage.listen(onMessage);
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService(
    ref.watch(messagingProvider),
    ref.watch(firestoreProvider),
    ref.watch(firebaseAuthProvider),
  );
});
