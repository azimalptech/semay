import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';
import 'firestore_service.dart';

class ChatService {
  ChatService(this._firestore, this._functions, this._auth);

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;

  /// Deterministic id — one thread per user<->store pair.
  static String chatIdFor(String uid, String storeId) => '${uid}_$storeId';

  Future<String> createOrGetChat(String storeId) async {
    final uid = _auth.currentUser!.uid;
    final chatId = chatIdFor(uid, storeId);
    final chatRef = _firestore.collection('chats').doc(chatId);
    final snap = await chatRef.get();
    if (!snap.exists) {
      await chatRef.set({
        'userId': uid,
        'storeId': storeId,
        'lastMessageText': '',
        'lastMessageAt': FieldValue.serverTimestamp(),
        'unreadByUser': 0,
        'unreadByAdmin': 0,
      });
    }
    return chatId;
  }

  /// Writes only the message doc — denormalized chat-doc fields
  /// (lastMessageText/lastMessageAt/unread counters) are the
  /// onMessageCreated trigger's job, same philosophy as postsCount.
  Future<void> sendMessage(String chatId, String text, {required String senderRole}) async {
    final uid = _auth.currentUser!.uid;
    await _firestore.collection('chats').doc(chatId).collection('messages').add({
      'senderId': uid,
      'senderRole': senderRole,
      'text': text,
      'mediaUrl': null,
      'orderId': null,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> markThreadRead(String chatId, {required bool asAdmin}) async {
    await _firestore.collection('chats').doc(chatId).update({
      asAdmin ? 'unreadByAdmin' : 'unreadByUser': 0,
    });
  }

  Future<String> acceptOrder({
    required String chatId,
    required String postId,
    required int itemQuantity,
    required String deliveryAddress,
    required String userPhone,
  }) async {
    final result = await _functions.httpsCallable('acceptOrder').call<Map<String, dynamic>>({
      'chatId': chatId,
      'postId': postId,
      'itemQuantity': itemQuantity,
      'deliveryAddress': deliveryAddress,
      'userPhone': userPhone,
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    return data['orderId'] as String;
  }
}

final chatServiceProvider = Provider<ChatService>((ref) {
  return ChatService(
    ref.watch(firestoreProvider),
    ref.watch(functionsProvider),
    ref.watch(firebaseAuthProvider),
  );
});
