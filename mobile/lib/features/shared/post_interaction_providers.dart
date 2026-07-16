import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../../services/firestore_service.dart';

/// Store name/avatar for a post's header row — cached per storeId.
final storeSummaryProvider = FutureProvider.family<Map<String, dynamic>?, String>((ref, storeId) async {
  if (storeId.isEmpty) return null;
  final snap = await ref.watch(firestoreProvider).collection('stores').doc(storeId).get();
  return snap.data();
});

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

