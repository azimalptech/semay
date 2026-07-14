import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firestore_service.dart';
import 'storage_service.dart';

class StoriesService {
  StoriesService(this._firestore, this._storage);

  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;

  static const _maxVideoBytes = 100 * 1024 * 1024;

  Future<void> createStory({
    required String storeId,
    required File mediaFile,
    required String mediaType, // "image" | "video"
  }) async {
    if (mediaType == 'video' && await mediaFile.length() > _maxVideoBytes) {
      throw Exception('Video must be under 100MB');
    }

    final storyRef = _firestore.collection('stories').doc();
    final ext = mediaType == 'video' ? 'mp4' : 'jpg';
    final ref = _storage.ref('stores/$storeId/stories/${storyRef.id}/media.$ext');
    await ref.putFile(mediaFile);
    final mediaUrl = await ref.getDownloadURL();

    final now = DateTime.now();
    await storyRef.set({
      'storeId': storeId,
      'mediaUrl': mediaUrl,
      'mediaType': mediaType,
      'createdAt': Timestamp.fromDate(now),
      'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 24))),
    });
  }

  Future<void> deleteStory(String storyId) async {
    await _firestore.collection('stories').doc(storyId).delete();
  }
}

final storiesServiceProvider = Provider<StoriesService>((ref) {
  return StoriesService(ref.watch(firestoreProvider), ref.watch(storageProvider));
});
