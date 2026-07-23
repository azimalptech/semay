import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'auth_service.dart';
import 'firestore_service.dart';
import 'notification_service.dart';
import 'storage_service.dart';

final functionsProvider = Provider<FirebaseFunctions>(
  (ref) => FirebaseFunctions.instance,
);

class ChatService {
  ChatService(this._firestore, this._functions, this._auth, this._storage);

  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;
  final FirebaseStorage _storage;

  static const _maxVideoBytes = 100 * 1024 * 1024;

  /// Uploads a gallery-picked photo/video attachment (not a "send to chat"
  /// shared post — see sendMessage's sharedPostId for that) and returns its
  /// download URL, ready to pass straight into sendMessage.
  Future<String> uploadChatMedia({
    required String chatId,
    required XFile file,
    required String mediaType, // "image" | "video"
  }) async {
    final bytes = await file.readAsBytes();
    if (mediaType == 'video' && bytes.length > _maxVideoBytes) {
      throw Exception('Video must be under 100MB');
    }
    final ext = mediaType == 'video' ? 'mp4' : 'jpg';
    final contentType = mediaType == 'video' ? 'video/mp4' : 'image/jpeg';
    final name = '${DateTime.now().millisecondsSinceEpoch}.$ext';
    final ref = _storage.ref('chats/$chatId/$name');
    await ref.putData(bytes, SettableMetadata(contentType: contentType));
    return ref.getDownloadURL();
  }

  /// Deterministic id — one thread per user<->store pair.
  static String chatIdFor(String uid, String storeId) => '${uid}_$storeId';

  Future<String> createOrGetChat(String storeId) async {
    final uid = _auth.currentUser!.uid;
    final chatId = chatIdFor(uid, storeId);
    final chatRef = _firestore.collection('chats').doc(chatId);
    final snap = await chatRef.get();
    if (!snap.exists) {
      // No lastMessageText/lastMessageAt here — userChatsProvider/
      // adminChatsProvider both orderBy('lastMessageAt', descending: true),
      // and Firestore excludes docs missing the ordered field from that
      // query entirely, so a chat with no real message yet correctly stays
      // out of the "recent conversations" list (chat_list_screen.dart's
      // merge shows it under "no messages yet" instead) rather than jumping
      // to the top just because someone opened the thread without sending
      // anything. onMessageCreated sets both fields the moment a real
      // message lands, which is what should actually promote it to "recent".
      await chatRef.set({
        'userId': uid,
        'storeId': storeId,
        'unreadByUser': 0,
        'unreadByAdmin': 0,
      });
      // .set() above resolves as soon as the write lands in the *local*
      // cache (offline persistence), not once the server has actually
      // committed it — but the messages/{messageId} create rule's get() on
      // this exact chat doc is evaluated server-side. Sending a first
      // message immediately after opening a brand-new chat (see
      // chat_list_screen.dart's "show every store, not just existing
      // chats" list) could reach the server before this doc did, and that
      // get() would find nothing and reject the message with
      // permission-denied. Waiting for a snapshot with no pending writes
      // confirms the server has actually seen it before returning.
      await chatRef.snapshots().firstWhere(
        (snap) => !snap.metadata.hasPendingWrites,
      );
    }
    return chatId;
  }

  /// Writes only the message doc — denormalized chat-doc fields
  /// (lastMessageText/lastMessageAt/unread counters) are the
  /// onMessageCreated trigger's job, same philosophy as postsCount.
  Future<void> sendMessage(
    String chatId,
    String text, {
    required String senderRole,
    String? sharedPostId,
    String? sharedStoryId,
    String? mediaUrl,
    String? mediaType, // "image" | "video" — only for a raw gallery attachment
    // Quoted-reply — replyToText/replyToSenderRole are denormalized off the
    // original message at send time (not a live reference) so the bubble
    // can render the quote without an extra read, same as sharedPost's own
    // preview fields.
    String? replyToMessageId,
    String? replyToText,
    String? replyToSenderRole,
  }) async {
    final uid = _auth.currentUser!.uid;
    final callStart = DateTime.now();
    debugPrint('ChatService.sendMessage: calling .add() at $callStart');
    final ref = await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .add({
          'senderId': uid,
          'senderRole': senderRole,
          'text': text,
          'mediaUrl': mediaUrl,
          'mediaType': mediaType,
          'orderId': null,
          'sharedPostId': sharedPostId,
          'sharedStoryId': sharedStoryId,
          'replyToMessageId': replyToMessageId,
          'replyToText': replyToText,
          'replyToSenderRole': replyToSenderRole,
          'createdAt': FieldValue.serverTimestamp(),
        });
    debugPrint(
      'ChatService.sendMessage: .add() resolved after '
      '${DateTime.now().difference(callStart).inMilliseconds}ms, id=${ref.id}',
    );
  }

  Future<void> markThreadRead(String chatId, {required bool asAdmin}) async {
    await _firestore.collection('chats').doc(chatId).update({
      asAdmin ? 'unreadByAdmin' : 'unreadByUser': 0,
    });
  }

  /// Soft per-side "delete from my list" — stamps hiddenByAdminAt/hiddenByUserAt
  /// with now, so the chat list filters this thread out for this side only
  /// (the other participant keeps it). Also zeroes this side's unread so the
  /// nav badge doesn't keep counting a chat the user just dismissed. It
  /// reappears in the list automatically once a newer message arrives
  /// (onMessageCreated bumps lastMessageAt past this hidden timestamp — see
  /// the filter in chat_list_screen.dart). Deliberately NOT a hard delete: the
  /// conversation, its messages, and any order history all stay intact for the
  /// other party.
  Future<void> hideChat(String chatId, {required bool asAdmin}) async {
    await _firestore.collection('chats').doc(chatId).update({
      asAdmin ? 'hiddenByAdminAt' : 'hiddenByUserAt':
          FieldValue.serverTimestamp(),
      asAdmin ? 'unreadByAdmin' : 'unreadByUser': 0,
    });
  }

  /// This device's currently-open chat thread, or null when none is open —
  /// read server-side by onMessageCreated to suppress a push notification
  /// for a chat the recipient is already looking at (see that function's
  /// comment). Set on ChatThreadScreen mount/foreground, cleared on
  /// dispose/background.
  Future<void> setActiveChat(String? chatId) async {
    // Synchronous, ahead of the Firestore write below — the foreground
    // notification banner (see notification_service.dart's
    // showForegroundMessageBanner) reads this instantly rather than racing
    // a network round-trip to decide whether to suppress itself.
    setLocallyActiveChatId(chatId);
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _firestore.collection('users').doc(uid).update({
      'activeChatId': chatId,
    });
  }

  /// Marks each of [messageIds] delivered — only meaningful for messages
  /// the caller *received* (didn't send); see firestore.rules, which
  /// enforces exactly that. A message already carrying deliveredAt is left
  /// alone rather than re-written, both to keep the original delivery
  /// timestamp and to avoid a pointless write.
  Future<void> markMessagesDelivered(
    String chatId,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> messages,
  ) async {
    final pending = messages.where((m) => m.data()['deliveredAt'] == null);
    if (pending.isEmpty) return;
    final batch = _firestore.batch();
    for (final message in pending) {
      batch.update(message.reference, {
        'deliveredAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  /// Read implies delivered — messages missing deliveredAt get it backfilled
  /// in the same batch (e.g. the recipient opened the thread for the first
  /// time and both effectively happen at once, rather than waiting on a
  /// separate FCM round-trip that may never come while foregrounded on this
  /// exact thread already).
  Future<void> markMessagesRead(
    String chatId,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> messages,
  ) async {
    final pending = messages.where((m) => m.data()['readAt'] == null);
    if (pending.isEmpty) return;
    final batch = _firestore.batch();
    final now = FieldValue.serverTimestamp();
    for (final message in pending) {
      final update = <String, Object?>{'readAt': now};
      if (message.data()['deliveredAt'] == null) update['deliveredAt'] = now;
      batch.update(message.reference, update);
    }
    await batch.commit();
  }

  Future<void> setChatMuted(
    String chatId, {
    required bool asAdmin,
    required bool muted,
  }) async {
    await _firestore.collection('chats').doc(chatId).update({
      asAdmin ? 'mutedByAdmin' : 'mutedByUser': muted,
    });
  }

  /// Heartbeat while composing — the other side shows "typing…" while the
  /// timestamp is fresh (staleness handles abandoned drafts, so there is no
  /// explicit "stopped typing" write besides clearing on send).
  Future<void> setTyping(
    String chatId, {
    required bool asAdmin,
    required bool isTyping,
  }) async {
    await _firestore.collection('chats').doc(chatId).update({
      asAdmin ? 'typingAdminAt' : 'typingUserAt': isTyping
          ? FieldValue.serverTimestamp()
          : null,
    });
  }

  Future<String> acceptOrder({
    required String chatId,
    required int itemQuantity,
    required String userPhone,
  }) async {
    final result = await _functions
        .httpsCallable('acceptOrder')
        .call<Map<String, dynamic>>({
          'chatId': chatId,
          'itemQuantity': itemQuantity,
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
    ref.watch(storageProvider),
  );
});
