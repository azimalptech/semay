import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'auth_service.dart';
import 'firestore_service.dart';
import 'storage_service.dart';

class PostsService {
  PostsService(this._firestore, this._storage, this._auth);

  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;
  final FirebaseAuth _auth;

  static const _maxVideoBytes = 100 * 1024 * 1024;

  /// XFile + putData (not dart:io File) so publishing works on web too.
  Future<void> createPost({
    required String storeId,
    required String type, // "image" | "carousel" | "reel"
    required List<XFile> files,
    required String caption,
  }) async {
    final postRef = _firestore.collection('posts').doc();
    final basePath = 'stores/$storeId/posts/${postRef.id}';

    final mediaUrls = <String>[];
    for (var i = 0; i < files.length; i++) {
      final bytes = await files[i].readAsBytes();
      if (type == 'reel' && bytes.length > _maxVideoBytes) {
        throw Exception('Video must be under 100MB');
      }
      final ext = type == 'reel' ? 'mp4' : 'jpg';
      final contentType = type == 'reel' ? 'video/mp4' : 'image/jpeg';
      final ref = _storage.ref('$basePath/media_$i.$ext');
      await ref.putData(bytes, SettableMetadata(contentType: contentType));
      mediaUrls.add(await ref.getDownloadURL());
    }

    // video_thumbnail has no web implementation — reels published from a
    // browser get an empty thumbnailUrl and grids fall back to the video URL.
    String thumbnailUrl = '';
    if (type == 'reel' && !kIsWeb) {
      final thumbBytes = await VideoThumbnail.thumbnailData(
        video: files.first.path,
        imageFormat: ImageFormat.JPEG,
      );
      if (thumbBytes != null) {
        final thumbRef = _storage.ref('$basePath/thumbnail.jpg');
        await thumbRef.putData(thumbBytes, SettableMetadata(contentType: 'image/jpeg'));
        thumbnailUrl = await thumbRef.getDownloadURL();
      }
    }

    await postRef.set({
      'storeId': storeId,
      'type': type,
      'mediaUrls': mediaUrls,
      'thumbnailUrl': thumbnailUrl,
      'caption': caption,
      'likesCount': 0,
      'savesCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deletePost(String postId) async {
    await _firestore.collection('posts').doc(postId).delete();
  }

  /// Instagram scopes post editing to the caption only — the media stays as
  /// uploaded, no re-crop/replace after publish.
  Future<void> updateCaption(String postId, String caption) async {
    await _firestore.collection('posts').doc(postId).update({'caption': caption});
  }

  Future<void> toggleLike(String postId) async {
    final uid = _auth.currentUser!.uid;
    final likeRef = _firestore.collection('posts').doc(postId).collection('likes').doc(uid);
    final likedRef = _firestore.collection('users').doc(uid).collection('liked').doc(postId);
    final snap = await likeRef.get();
    final batch = _firestore.batch();
    if (snap.exists) {
      batch.delete(likeRef);
      batch.delete(likedRef);
    } else {
      batch.set(likeRef, {'createdAt': FieldValue.serverTimestamp()});
      batch.set(likedRef, {'createdAt': FieldValue.serverTimestamp()});
    }
    await batch.commit();
  }

  Future<void> toggleSave(String postId) async {
    final uid = _auth.currentUser!.uid;
    final savedRef = _firestore.collection('users').doc(uid).collection('saved').doc(postId);
    final snap = await savedRef.get();
    if (snap.exists) {
      await savedRef.delete();
    } else {
      await savedRef.set({'createdAt': FieldValue.serverTimestamp()});
    }
  }
}

final postsServiceProvider = Provider<PostsService>((ref) {
  return PostsService(
    ref.watch(firestoreProvider),
    ref.watch(storageProvider),
    ref.watch(firebaseAuthProvider),
  );
});
