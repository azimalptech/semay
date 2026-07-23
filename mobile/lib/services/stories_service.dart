import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'auth_service.dart';
import 'firestore_service.dart';
import 'storage_service.dart';

class StoriesService {
  StoriesService(this._firestore, this._storage, this._auth);

  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;
  final FirebaseAuth _auth;

  static const _maxVideoBytes = 100 * 1024 * 1024;

  /// XFile + putData (not dart:io File) so publishing works on web too.
  Future<void> createStory({
    required String storeId,
    required XFile mediaFile,
    required String mediaType, // "image" | "video"
  }) async {
    final bytes = await mediaFile.readAsBytes();
    if (mediaType == 'video' && bytes.length > _maxVideoBytes) {
      throw Exception('Video must be under 100MB');
    }

    final storyRef = _firestore.collection('stories').doc();
    final ext = mediaType == 'video' ? 'mp4' : 'jpg';
    final contentType = mediaType == 'video' ? 'video/mp4' : 'image/jpeg';
    final ref = _storage.ref(
      'stores/$storeId/stories/${storyRef.id}/media.$ext',
    );
    await ref.putData(bytes, SettableMetadata(contentType: contentType));
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

  /// Marks a store's current story sequence as watched-to-the-end for the
  /// signed-in user — the story bar greys that ring out and sorts it last.
  Future<void> markStoreSeen(String storeId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('storySeen')
        .doc(storeId)
        .set({'seenAt': FieldValue.serverTimestamp()});
  }

  /// Per-story unique-viewer record (doc id = viewer uid, so rewatching
  /// can't inflate the count) — powers the owner's "seen by N".
  Future<void> recordStoryView(String storyId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _firestore
        .collection('stories')
        .doc(storyId)
        .collection('views')
        .doc(uid)
        .set({'viewedAt': FieldValue.serverTimestamp()});
  }
}

/// How many unique users watched this story — shown to the owning store's
/// admin in the story viewer footer.
final storyViewCountProvider = StreamProvider.family<int, String>((
  ref,
  storyId,
) {
  return ref
      .watch(firestoreProvider)
      .collection('stories')
      .doc(storyId)
      .collection('views')
      .snapshots()
      .map((snap) => snap.docs.length);
}, isAutoDispose: true);

final storiesServiceProvider = Provider<StoriesService>((ref) {
  return StoriesService(
    ref.watch(firestoreProvider),
    ref.watch(storageProvider),
    ref.watch(firebaseAuthProvider),
  );
});
