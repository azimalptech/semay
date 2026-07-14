import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  Future<void> createPost({
    required String storeId,
    required String type, // "image" | "carousel" | "reel"
    required List<File> files,
    required String caption,
  }) async {
    if (type == 'reel' && await files.first.length() > _maxVideoBytes) {
      throw Exception('Video must be under 100MB');
    }

    final postRef = _firestore.collection('posts').doc();
    final basePath = 'stores/$storeId/posts/${postRef.id}';

    final mediaUrls = <String>[];
    for (var i = 0; i < files.length; i++) {
      final ext = type == 'reel' ? 'mp4' : 'jpg';
      final ref = _storage.ref('$basePath/media_$i.$ext');
      await ref.putFile(files[i]);
      mediaUrls.add(await ref.getDownloadURL());
    }

    String thumbnailUrl = '';
    if (type == 'reel') {
      final thumbPath = await VideoThumbnail.thumbnailFile(
        video: files.first.path,
        imageFormat: ImageFormat.JPEG,
      );
      if (thumbPath != null) {
        final thumbRef = _storage.ref('$basePath/thumbnail.jpg');
        await thumbRef.putFile(File(thumbPath));
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
      'commentsCount': 0,
      'savesCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deletePost(String postId) async {
    await _firestore.collection('posts').doc(postId).delete();
  }

  Future<void> toggleLike(String postId) async {
    final uid = _auth.currentUser!.uid;
    final likeRef = _firestore.collection('posts').doc(postId).collection('likes').doc(uid);
    final snap = await likeRef.get();
    if (snap.exists) {
      await likeRef.delete();
    } else {
      await likeRef.set({'createdAt': FieldValue.serverTimestamp()});
    }
  }

  Future<void> addComment(String postId, String text) async {
    final user = _auth.currentUser!;
    await _firestore.collection('posts').doc(postId).collection('comments').add({
      'uid': user.uid,
      'userName': user.displayName ?? '',
      'text': text,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Shared path for both self-delete and store-admin moderation delete —
  /// firestore.rules decides who's allowed, this call is identical either way.
  Future<void> deleteComment(String postId, String commentId) async {
    await _firestore.collection('posts').doc(postId).collection('comments').doc(commentId).delete();
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
