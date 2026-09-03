import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../core/outbox.dart';
import 'notification_service.dart';

class ChatService {
  ChatService(this._api, this._outbox);

  final ApiClient _api;
  final OutboxService _outbox;

  static const _maxVideoBytes = 100 * 1024 * 1024;

  /// Sends a gallery photo/video the way text is sent: through the outbox.
  /// The bubble appears immediately (rendering the local file, with a
  /// progress ring), the outbox uploads then posts — with the same retry,
  /// idempotency and "not sent, tap to retry" as text — and the upload URL is
  /// remembered on the queued row so a retry never re-uploads. Previously the
  /// screen blocked on the upload with a spinner and a flaky connection lost
  /// the attachment altogether.
  ///
  /// The file is copied into app storage first: the picker hands back a temp
  /// file the OS may reclaim before a slow send completes. Images arrive
  /// already downscaled/recompressed by the picker (see the thread screen's
  /// pickMedia call); videos are sent as picked, capped at [_maxVideoBytes].
  Future<String> sendMediaMessage(
    String chatId, {
    required XFile file,
    required String mediaType, // "image" | "video"
    required String senderRole,
  }) async {
    // Store admins only (product decision; the server's /media/upload-url
    // refuses everyone else, so a customer's attachment could never send).
    if (senderRole != 'admin') {
      throw StateError('Only store admins can send attachments');
    }
    if (mediaType == 'video' && await file.length() > _maxVideoBytes) {
      throw Exception('Video must be under 100MB');
    }
    final key = _outbox.newKey();
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'chat_outbox'));
    await dir.create(recursive: true);
    final ext = mediaType == 'video' ? 'mp4' : 'jpg';
    final copy = p.join(dir.path, '$key.$ext');
    await file.saveTo(copy);
    await _outbox.enqueue(OutboxKind.message, {
      'chatId': chatId,
      'text': '',
      'senderRole': senderRole, // carried for the optimistic bubble only
      'mediaType': mediaType,
      'localMediaPath': copy,
    }, id: key);
    return key;
  }

  /// Deterministic id — one thread per user<->store pair. Kept for callers
  /// that predict the id; the server uses the same scheme.
  static String chatIdFor(String uid, String storeId) => '${uid}_$storeId';

  /// Creates (or returns the existing) chat for this user + store. The server
  /// does an idempotent upsert on the deterministic PK, so the old
  /// !hasPendingWrites race is structurally gone (see docs/07_MIGRATION.md).
  Future<String> createOrGetChat(String storeId) async {
    final json = await _api.post('/chats', body: {'storeId': storeId});
    return (json['chat'] as Map<String, dynamic>)['id'] as String;
  }

  /// Enqueues the message on the offline outbox (Phase 9b) — which sends it
  /// immediately when online and replays it on reconnect when offline, keyed
  /// by a client-generated idempotency key so a retry never double-sends. The
  /// server updates the chat's denormalized last-message/unread fields and
  /// publishes to every realtime channel; the `senderRole`/side is inferred
  /// server-side from the caller's role. Returns the outbox item's clientKey
  /// so the UI can render an optimistic "sending…" bubble.
  Future<String> sendMessage(
    String chatId,
    String text, {
    required String senderRole,
    String? sharedPostId,
    String? sharedStoryId,
    String? mediaUrl,
    String? mediaType, // "image" | "video"
    String? replyToMessageId,
    String? replyToText,
    String? replyToSenderRole,
  }) async {
    final key = _outbox.newKey();
    final payload = <String, dynamic>{
      'chatId': chatId,
      'text': text,
      'senderRole': senderRole, // carried for the optimistic bubble only
    };
    if (sharedPostId != null) payload['sharedPostId'] = sharedPostId;
    if (sharedStoryId != null) payload['sharedStoryId'] = sharedStoryId;
    if (mediaUrl != null) payload['mediaUrl'] = mediaUrl;
    if (mediaType != null) payload['mediaType'] = mediaType;
    if (replyToMessageId != null) payload['replyToMessageId'] = replyToMessageId;
    if (replyToText != null) payload['replyToText'] = replyToText;
    if (replyToSenderRole != null) payload['replyToSenderRole'] = replyToSenderRole;
    await _outbox.enqueue(OutboxKind.message, payload, id: key);
    return key;
  }

  /// Zeroes this side's unread counter (opening the thread). The receipts
  /// endpoint marks the other side's messages read AND clears the caller's
  /// unread in one call — the server infers which side the caller is.
  Future<void> markThreadRead(String chatId, {required bool asAdmin}) async {
    await _api.post('/chats/$chatId/receipts', body: {'status': 'read'});
  }

  /// Soft per-side "delete from my list" — the server stamps
  /// hiddenBy{User,Admin}At for the caller's side and zeroes their unread; the
  /// thread reappears once a newer message arrives (see chat_list filter).
  Future<void> hideChat(String chatId, {required bool asAdmin}) async {
    await _api.delete('/chats/$chatId');
  }

  /// This device's currently-open chat. The synchronous local flag is what
  /// suppresses the in-app banner for a message from the thread on screen;
  /// the server copy (users.activeChatId) is kept up to date as a diagnostic
  /// hint only — it no longer gates pushes or unread counts, because a killed
  /// app left it stuck and silenced the chat (see server chats/service.ts).
  Future<void> setActiveChat(String? chatId) async {
    setLocallyActiveChatId(chatId);
    await _api.patch('/users/me', body: {'activeChatId': chatId});
  }

  /// Marks everything the other side sent in this chat as delivered — called
  /// by the chat-list providers the moment a chat's unread count rises on
  /// this device (see chat_providers.dart's _DeliveryMarker). Server-side a
  /// no-op when nothing is pending, so it is safe to call generously.
  Future<void> markDelivered(String chatId) async {
    await _api.post('/chats/$chatId/receipts', body: {'status': 'delivered'});
  }

  /// Marks the counterpart's messages delivered. One receipts call regardless
  /// of how many messages — no-op if nothing from the other side is pending.
  Future<void> markMessagesDelivered(
    String chatId,
    List<Map<String, dynamic>> messages,
  ) async {
    if (messages.every((m) => m['deliveredAt'] != null)) return;
    await _api.post('/chats/$chatId/receipts', body: {'status': 'delivered'});
  }

  Future<void> markMessagesRead(
    String chatId,
    List<Map<String, dynamic>> messages,
  ) async {
    if (messages.every((m) => m['readAt'] != null)) return;
    await _api.post('/chats/$chatId/receipts', body: {'status': 'read'});
  }

  Future<void> setChatMuted(
    String chatId, {
    required bool asAdmin,
    required bool muted,
  }) async {
    await _api.post('/chats/$chatId/mute', body: {'muted': muted});
  }

  /// Heartbeat while composing — the other side shows "typing…" while the
  /// timestamp is fresh; the server clears it when [isTyping] is false.
  Future<void> setTyping(
    String chatId, {
    required bool asAdmin,
    required bool isTyping,
  }) async {
    await _api.post('/chats/$chatId/typing', body: {'typing': isTyping});
  }

  Future<String> acceptOrder({
    required String chatId,
    required int itemQuantity,
    required String userPhone, // ignored — server auto-fills from the customer
    // Idempotency key: the server collapses a retry carrying the same key onto
    // the original order instead of recording a second sale. Optional so this
    // stays compatible with any caller that hasn't been updated.
    String? clientKey,
  }) async {
    final json = await _api.post(
      '/chats/$chatId/orders',
      body: {
        'itemQuantity': itemQuantity,
        'clientKey': ?clientKey,
      },
    );
    return (json['order'] as Map<String, dynamic>)['id'] as String;
  }
}

final chatServiceProvider = Provider<ChatService>((ref) {
  return ChatService(
    ref.watch(apiClientProvider),
    ref.watch(outboxServiceProvider),
  );
});
