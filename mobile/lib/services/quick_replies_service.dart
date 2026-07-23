import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firestore_service.dart';

class QuickRepliesService {
  QuickRepliesService(this._firestore);

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _collection(String storeId) =>
      _firestore.collection('stores').doc(storeId).collection('quickReplies');

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> watch(
    String storeId,
  ) {
    return _collection(
      storeId,
    ).orderBy('order').snapshots().map((snap) => snap.docs);
  }

  Future<void> add(String storeId, String text, int order) async {
    await _collection(storeId).add({
      'text': text,
      'order': order,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> update(String storeId, String replyId, String text) async {
    await _collection(storeId).doc(replyId).update({'text': text});
  }

  Future<void> delete(String storeId, String replyId) async {
    await _collection(storeId).doc(replyId).delete();
  }
}

final quickRepliesServiceProvider = Provider<QuickRepliesService>((ref) {
  return QuickRepliesService(ref.watch(firestoreProvider));
});
