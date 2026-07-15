import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../../services/firestore_service.dart';

typedef ChatDoc = QueryDocumentSnapshot<Map<String, dynamic>>;

/// A plain user's conversations, one per store they've messaged.
final userChatsProvider = StreamProvider<List<ChatDoc>>((ref) {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return Stream.value([]);

  return ref
      .watch(firestoreProvider)
      .collection('chats')
      .where('userId', isEqualTo: user.uid)
      .orderBy('lastMessageAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs);
});

/// A store admin's conversations, across all stores they manage.
/// Not `.family` — a `List<String>` arg has no value equality.
final adminChatsProvider = StreamProvider<List<ChatDoc>>((ref) async* {
  final storeIds = await ref.watch(storeIdsProvider.future);
  if (storeIds.isEmpty) {
    yield [];
    return;
  }

  yield* ref
      .watch(firestoreProvider)
      .collection('chats')
      .where('storeId', whereIn: storeIds)
      .orderBy('lastMessageAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs);
});

final chatDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((ref, chatId) {
  return ref
      .watch(firestoreProvider)
      .collection('chats')
      .doc(chatId)
      .snapshots()
      .map((snap) => snap.data());
});

final chatMessagesProvider = StreamProvider.family<List<ChatDoc>, String>((ref, chatId) {
  return ref
      .watch(firestoreProvider)
      .collection('chats')
      .doc(chatId)
      .collection('messages')
      .orderBy('createdAt')
      .limit(200)
      .snapshots()
      .map((snap) => snap.docs);
});

/// Structural twin of `storeDocProvider` — lets the admin side show the
/// customer's name/phone.
final userDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((ref, uid) {
  return ref
      .watch(firestoreProvider)
      .collection('users')
      .doc(uid)
      .snapshots()
      .map((snap) => snap.data());
});
