import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
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
    num? price,
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
        await thumbRef.putData(
          thumbBytes,
          SettableMetadata(contentType: 'image/jpeg'),
        );
        thumbnailUrl = await thumbRef.getDownloadURL();
      }
    }

    await postRef.set({
      'storeId': storeId,
      'type': type,
      'mediaUrls': mediaUrls,
      'thumbnailUrl': thumbnailUrl,
      'caption': caption,
      'price': price,
      'likesCount': 0,
      'savesCount': 0,
      'viewsCount': 0,
      'sentCount': 0,
      'sharesCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deletePost(String postId) async {
    await _firestore.collection('posts').doc(postId).delete();
  }

  /// Instagram scopes post editing to the caption only — the media stays as
  /// uploaded, no re-crop/replace after publish.
  Future<void> updateCaption(String postId, String caption) async {
    await _firestore.collection('posts').doc(postId).update({
      'caption': caption,
    });
  }

  /// Unique-viewer record (doc id = viewer uid, so re-triggering the same
  /// engagement signal — e.g. liking, then later zooming — never inflates
  /// the count past one per viewer), same shape as StoriesService's own
  /// recordStoryView. onViewCreated (backend) increments posts/{postId}.
  /// viewsCount off the doc actually being *created* — Cloud Functions'
  /// onDocumentCreated only fires on genuine creation, so calling this
  /// repeatedly for the same viewer is already safe without an existence
  /// check of its own.
  Future<void> recordView(String postId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _firestore
        .collection('posts')
        .doc(postId)
        .collection('views')
        .doc(uid)
        .set({'viewedAt': FieldValue.serverTimestamp()});
  }

  /// Unique-per-sender record, same shape/rationale as [recordView] — the
  /// same person sending this post to chat twice (or sharing it twice)
  /// counts once, not twice. Callers are responsible for only calling this
  /// once the underlying action has actually succeeded (a confirmed chat
  /// send, or a share sheet result of `ShareResultStatus.success`), not on
  /// the icon tap itself — see send_to_chat_sheet.dart / shareAndRecord.
  Future<void> recordSent(String postId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _firestore
        .collection('posts')
        .doc(postId)
        .collection('sent')
        .doc(uid)
        .set({'sentAt': FieldValue.serverTimestamp()});
  }

  Future<void> recordShare(String postId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _firestore
        .collection('posts')
        .doc(postId)
        .collection('shares')
        .doc(uid)
        .set({'sharedAt': FieldValue.serverTimestamp()});
  }

  /// Shared by every "share" icon (post_card.dart, post_detail_screen.dart,
  /// reel_player_view.dart) — only records the share if the OS share sheet
  /// reports the user actually completed a share (not dismissed/cancelled).
  /// Returns whether it actually counted, so callers can decide whether to
  /// show a "Shared" confirmation.
  Future<bool> shareAndRecord(String postId) async {
    final result = await SharePlus.instance.share(
      ShareParams(uri: Uri.parse('semay://post/$postId')),
    );
    if (result.status != ShareResultStatus.success) return false;
    await recordShare(postId);
    return true;
  }

  // Takes the caller's already-decided target state instead of reading
  // current existence itself and deciding create-vs-delete here. That
  // read-then-decide shape was the actual bug behind the like count
  // glitching on a quick like/unlike/like: two overlapping toggleLike()
  // calls each read likeRef.get() independently, and whichever read landed
  // before the OTHER call's write had committed could both decide the SAME
  // action (e.g. both "create") — silently contradicting the second tap's
  // real intent once both writes settled, which the UI only found out about
  // when isLikedProvider's listener delivered the true state a moment
  // later, flipping the heart back unexpectedly. LikeNotifier.toggle()
  // already computes the definitive intended state synchronously before
  // calling this, so handing it straight through and doing a plain
  // set/delete (no read) makes the outcome deterministic: Firestore
  // serializes writes to the same document in commit order, so the last tap
  // to actually commit always wins — which is exactly the right semantics
  // for rapid toggling, and removes the race entirely.
  Future<void> toggleLike(String postId, bool isLiked) async {
    final uid = _auth.currentUser!.uid;
    final likeRef = _firestore
        .collection('posts')
        .doc(postId)
        .collection('likes')
        .doc(uid);
    final likedRef = _firestore
        .collection('users')
        .doc(uid)
        .collection('liked')
        .doc(postId);
    final batch = _firestore.batch();
    if (isLiked) {
      batch.set(likeRef, {'createdAt': FieldValue.serverTimestamp()});
      batch.set(likedRef, {'createdAt': FieldValue.serverTimestamp()});
    } else {
      batch.delete(likeRef);
      batch.delete(likedRef);
    }
    await batch.commit();
  }

  Future<void> toggleSave(String postId) async {
    final uid = _auth.currentUser!.uid;
    final savedRef = _firestore
        .collection('users')
        .doc(uid)
        .collection('saved')
        .doc(postId);
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
