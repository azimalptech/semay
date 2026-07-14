import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../../services/firestore_service.dart';

final postDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((ref, postId) {
  return ref
      .watch(firestoreProvider)
      .collection('posts')
      .doc(postId)
      .snapshots()
      .map((snap) => snap.data());
});

final isLikedProvider = StreamProvider.family<bool, String>((ref, postId) {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return Stream.value(false);

  return ref
      .watch(firestoreProvider)
      .collection('posts')
      .doc(postId)
      .collection('likes')
      .doc(user.uid)
      .snapshots()
      .map((snap) => snap.exists);
});

final isSavedProvider = StreamProvider.family<bool, String>((ref, postId) {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return Stream.value(false);

  return ref
      .watch(firestoreProvider)
      .collection('users')
      .doc(user.uid)
      .collection('saved')
      .doc(postId)
      .snapshots()
      .map((snap) => snap.exists);
});

final commentsProvider =
    StreamProvider.family<List<QueryDocumentSnapshot<Map<String, dynamic>>>, String>((ref, postId) {
  return ref
      .watch(firestoreProvider)
      .collection('posts')
      .doc(postId)
      .collection('comments')
      .orderBy('createdAt')
      .limit(200)
      .snapshots()
      .map((snap) => snap.docs);
});
