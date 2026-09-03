import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';
import '../../core/outbox.dart';
import '../../core/realtime_client.dart';
import '../../services/auth_service.dart';
import '../../services/chat_service.dart';

/// A chat or message from the REST/WS API — flat JSON map with `id` inside,
/// wrapped so screens keep reading `doc.id` / `doc.data()['field']`.
typedef ChatDoc = JsonDoc;

DateTime? _lastMessageAt(Map<String, dynamic> chat) =>
    parseTimestamp(chat['lastMessageAt']);

int _byLastMessageDesc(Map<String, dynamic> a, Map<String, dynamic> b) {
  final at = _lastMessageAt(a);
  final bt = _lastMessageAt(b);
  if (at == null && bt == null) return 0;
  if (at == null) return 1;
  if (bt == null) return -1;
  return bt.compareTo(at);
}

/// A chat should show in a list only while it isn't hidden for this side, or a
/// newer message has arrived since it was hidden — same "swipe-delete
/// reappears on new message" rule the server's listUserChats/listStoreChats
/// enforce, re-applied client-side because the realtime channel also delivers
/// the chat's own hide-state changes.
bool _visibleFor(Map<String, dynamic> chat, {required bool admin}) {
  final hiddenAt = parseTimestamp(chat[admin ? 'hiddenByAdminAt' : 'hiddenByUserAt']);
  if (hiddenAt == null) return true;
  final last = _lastMessageAt(chat);
  return last != null && last.isAfter(hiddenAt);
}

int _myUnread(Map<String, dynamic> chat, {required bool admin}) =>
    chat[admin ? 'unreadByAdmin' : 'unreadByUser'] as int? ?? 0;

/// Total unread messages across every conversation for the current role —
/// drives the Chat tab's nav-bar badge.
final totalUnreadChatCountProvider = Provider<int>((ref) {
  final role = ref.watch(appRoleProvider).value;
  final isAdmin = role == AppRole.admin || role == AppRole.superadmin;
  final chats = isAdmin
      ? ref.watch(adminChatsProvider).value
      : ref.watch(userChatsProvider).value;
  if (chats == null) return 0;
  return chats.fold<int>(0, (t, doc) => t + _myUnread(doc.data(), admin: isAdmin));
});

/// Every active store — merged with userChatsProvider in chat_list_screen so a
/// plain user's chat list shows every store by default (tapping one with no
/// prior conversation lazily creates the chat).
final activeStoresProvider = FutureProvider<List<ChatDoc>>((ref) async {
  final json = await ref.watch(apiClientProvider).get('/stores');
  final list = (json['stores'] as List<dynamic>? ?? const []);
  return list.map((e) => ChatDoc(e as Map<String, dynamic>)).toList();
});

/// Turns "my unread count for this chat went up" into a delivered receipt.
///
/// That is the moment a message provably reached this device, which is what
/// the sender's second grey check means. It used to be stamped only by the
/// FCM handler — so without push (no service account on the server, a muted
/// chat, notifications refused on the device, or simply push arriving after
/// the socket) the sender's message stayed single-checked even though the
/// recipient was looking at the list with a badge on it. The receipts
/// endpoint is a no-op (no publish) when nothing is pending, so calling it on
/// every rise is cheap.
class _DeliveryMarker {
  _DeliveryMarker(this._ref);

  final Ref _ref;
  final _prevUnread = <String, int>{};
  final _inFlight = <String>{};
  // A rise that lands while a receipt for the same chat is still in flight —
  // the server may have stamped before the newer message was inserted, so
  // one more receipt goes out once the current one settles.
  final _dirty = <String>{};

  /// Call for every chat the channel delivers — snapshot rows and upserts
  /// alike. Only a RISE in my unread triggers a receipt, so the snapshot that
  /// follows every reconnect re-marks just the chats that actually gained
  /// messages while the socket was down, not every chat with a badge.
  void observe(Map<String, dynamic> chat, {required bool admin}) {
    final id = chat['id'] as String;
    final unread = _myUnread(chat, admin: admin);
    final prev = _prevUnread[id] ?? 0;
    _prevUnread[id] = unread;
    if (unread > prev) _mark(id);
  }

  Future<void> _mark(String chatId) async {
    if (_inFlight.contains(chatId)) {
      _dirty.add(chatId);
      return;
    }
    _inFlight.add(chatId);
    try {
      await _ref.read(chatServiceProvider).markDelivered(chatId);
    } catch (_) {
      // Best-effort; the thread marks read (which implies delivered) on open.
    } finally {
      _inFlight.remove(chatId);
      if (_dirty.remove(chatId)) unawaited(_mark(chatId));
    }
  }
}

/// Maintains a keyed list from a single realtime list-channel's snapshot/
/// upsert/remove events, sorted by last activity, filtered by hide-state.
///
/// An explicit `.listen` cancelled synchronously in `ref.onDispose`, not an
/// `async*` generator: a generator's cancel only lands at its next yield, so
/// when the provider rebuilt (token refresh) the old listener was still on
/// the RealtimeClient's channel, the new one found it there, no fresh
/// subscribe frame went out, and the list collapsed to whichever chat next
/// changed — until the socket happened to reconnect.
Stream<List<ChatDoc>> _chatListChannel(
  Ref ref,
  String channel, {
  required bool admin,
}) {
  final controller = StreamController<List<ChatDoc>>();
  final byId = <String, Map<String, dynamic>>{};
  final delivery = _DeliveryMarker(ref);

  void emit() {
    final visible = byId.values.where((c) => _visibleFor(c, admin: admin)).toList()
      ..sort(_byLastMessageDesc);
    if (!controller.isClosed) controller.add(visible.map((c) => ChatDoc(c)).toList());
  }

  final sub = ref.watch(realtimeClientProvider).subscribe(channel).listen((e) {
    switch (e.type) {
      case RealtimeEventType.snapshot:
        byId.clear();
        for (final item in (e.data as List<dynamic>? ?? const [])) {
          final chat = item as Map<String, dynamic>;
          byId[chat['id'] as String] = chat;
          delivery.observe(chat, admin: admin);
        }
      case RealtimeEventType.upsert:
        final chat = e.data as Map<String, dynamic>;
        byId[chat['id'] as String] = chat;
        delivery.observe(chat, admin: admin);
      case RealtimeEventType.remove:
        if (e.removedId != null) byId.remove(e.removedId);
      case RealtimeEventType.receipts:
      case RealtimeEventType.error:
        return;
    }
    emit();
  });

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });
  return controller.stream;
}

/// A plain user's conversations, live via `user:{uid}:chats`.
///
/// Watches only the uid, not the whole session: a token refresh replaces the
/// SessionClaims object every 15 minutes, and rebuilding on that meant
/// resubscribing (a fresh 100-chat snapshot) for no change at all.
final userChatsProvider = StreamProvider<List<ChatDoc>>((ref) {
  final uid = ref.watch(authStateChangesProvider.select((s) => s.value?.uid));
  if (uid == null) return Stream.value(const <ChatDoc>[]);
  return _chatListChannel(ref, 'user:$uid:chats', admin: false);
});

/// A store admin's conversations across every store they manage — one
/// `store:{id}:chats` channel per store, merged client-side (the channel is
/// per-store by design; see docs/07_MIGRATION.md). The server snapshot caps at
/// the most recent 100 per store, replacing the old client-side pagination.
final adminChatsProvider = StreamProvider<List<ChatDoc>>((ref) {
  // Same reasoning as userChatsProvider: only the store set matters, not the
  // token that carried it.
  final storeKey = ref.watch(
    authStateChangesProvider.select((s) => s.value?.storeIds.join(',')),
  );
  final storeIds = (storeKey ?? '').split(',').where((s) => s.isNotEmpty).toList();

  final controller = StreamController<List<ChatDoc>>();
  final byId = <String, Map<String, dynamic>>{}; // chatId -> chat, all stores
  final subs = <StreamSubscription<dynamic>>[];
  final delivery = _DeliveryMarker(ref);

  void emit() {
    final list = byId.values.where((c) => _visibleFor(c, admin: true)).toList()
      ..sort(_byLastMessageDesc);
    if (!controller.isClosed) {
      controller.add(list.map((c) => ChatDoc(c)).toList());
    }
  }

  if (storeIds.isEmpty) {
    emit();
  }
  for (final storeId in storeIds) {
    final sub = ref
        .watch(realtimeClientProvider)
        .subscribe('store:$storeId:chats')
        .listen((e) {
          switch (e.type) {
            case RealtimeEventType.snapshot:
              // Replace just this store's entries.
              byId.removeWhere((_, c) => c['storeId'] == storeId);
              for (final item in (e.data as List<dynamic>? ?? const [])) {
                final chat = item as Map<String, dynamic>;
                byId[chat['id'] as String] = chat;
                delivery.observe(chat, admin: true);
              }
            case RealtimeEventType.upsert:
              final chat = e.data as Map<String, dynamic>;
              byId[chat['id'] as String] = chat;
              delivery.observe(chat, admin: true);
            case RealtimeEventType.remove:
              if (e.removedId != null) byId.remove(e.removedId);
            case RealtimeEventType.receipts:
            case RealtimeEventType.error:
              return;
          }
          emit();
        });
    subs.add(sub);
  }

  ref.onDispose(() {
    for (final s in subs) {
      s.cancel();
    }
    controller.close();
  });
  return controller.stream;
});

/// Only the admin's conversations with unread messages — derived from the same
/// live channel data, so the nav badge stays exact.
final adminUnreadChatsProvider = Provider<List<ChatDoc>>((ref) {
  final chats = ref.watch(adminChatsProvider).value ?? const [];
  return chats
      .where((c) => (c.data()['unreadByAdmin'] as int? ?? 0) > 0)
      .toList();
});

/// Live single chat doc via `chat:{id}` — carries typing/mute/unread state.
final chatDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((
  ref,
  chatId,
) async* {
  final api = ref.watch(apiClientProvider);
  Map<String, dynamic>? current;
  try {
    final json = await api.get('/chats/$chatId');
    current = json['chat'] as Map<String, dynamic>?;
    yield current;
  } catch (_) {
    yield null;
  }
  await for (final e in ref.watch(realtimeClientProvider).subscribe('chat:$chatId')) {
    if (e.type == RealtimeEventType.snapshot || e.type == RealtimeEventType.upsert) {
      current = e.data as Map<String, dynamic>?;
      yield current;
    }
  }
}, isAutoDispose: true);

int _messageId(Map<String, dynamic> m) => int.tryParse('${m['id']}') ?? 0;

/// Applies a `receipts` roll-up the way the server's updateMany did: every
/// message from `senderRole` up to `upToMessageId` (the newest row the server
/// actually stamped — a message that arrived over the socket a moment before
/// the receipt was NOT in that set, and stamping it would show "Seen" for a
/// message nobody has seen) that is still missing the stamp gets it. Copies
/// rather than mutating, so lists already handed to the UI are never edited
/// under it.
void _applyReceipts(Map<String, Map<String, dynamic>> byId, Map<String, dynamic> receipt) {
  final role = receipt['senderRole'];
  final status = receipt['status'];
  final at = receipt['at'];
  final upTo = int.tryParse('${receipt['upToMessageId']}');
  for (final entry in byId.entries.toList()) {
    final m = entry.value;
    if (m['senderRole'] != role) continue;
    if (upTo != null && _messageId(m) > upTo) continue;
    if (status == 'read') {
      if (m['readAt'] != null) continue;
      byId[entry.key] = {...m, 'readAt': at, 'deliveredAt': at};
    } else {
      if (m['deliveredAt'] != null) continue;
      byId[entry.key] = {...m, 'deliveredAt': at};
    }
  }
}

/// Live message list via `chat:{id}:messages`, oldest-first (the ListView
/// expects ascending; the server sends newest-first, so reverse). The snapshot
/// is the recent window; each new message arrives as an upsert, each receipt
/// as a `receipts` roll-up.
///
/// Three feeds merge here:
///  * a one-shot REST fetch for the fastest first paint — and so the thread
///    still loads when the socket can't connect but REST can;
///  * the socket (snapshot → upserts/receipts), authoritative once it lands;
///  * the outbox: the moment the server accepts one of OUR messages (POST
///    response) that row lands here directly rather than waiting for its echo
///    — see SentMessage for the vanishing-bubble bug that fixed.
final chatMessagesProvider = StreamProvider.family<List<ChatDoc>, String>((
  ref,
  chatId,
) {
  final controller = StreamController<List<ChatDoc>>();
  final byId = <String, Map<String, dynamic>>{};
  var seeded = false; // something authoritative has been shown

  List<ChatDoc> current() {
    final list = byId.values.toList()
      ..sort((a, b) => _messageId(a).compareTo(_messageId(b))); // oldest -> newest
    return list.map((m) => ChatDoc(m)).toList();
  }

  void emit() {
    // Nothing before the first seed/snapshot: an emission holding only the
    // one message we just sent would paint a near-empty thread for a frame.
    if (seeded && !controller.isClosed) controller.add(current());
  }

  /// A late arrival must never regress a stamp already applied from a
  /// receipts event — the POST response can land after the socket echo.
  void upsert(Map<String, dynamic> m) {
    final id = '${m['id']}';
    final existing = byId[id];
    if (existing == null) {
      byId[id] = m;
      return;
    }
    byId[id] = {
      ...m,
      'deliveredAt': m['deliveredAt'] ?? existing['deliveredAt'],
      'readAt': m['readAt'] ?? existing['readAt'],
    };
  }

  /// Replaces the window the server sent, but keeps anything newer than its
  /// newest row: an upsert (or our own POST response) that raced the snapshot
  /// query is not in it, and wiping it hid a message until the thread was
  /// reopened. Ids are monotonic, so "newer" is one comparison.
  void mergeSnapshot(List<dynamic> rows) {
    var maxId = 0;
    final incoming = <String, Map<String, dynamic>>{};
    for (final item in rows) {
      final m = item as Map<String, dynamic>;
      incoming['${m['id']}'] = m;
      maxId = max(maxId, _messageId(m));
    }
    final newer = {
      for (final e in byId.entries)
        if (_messageId(e.value) > maxId) e.key: e.value,
    };
    byId
      ..clear()
      ..addAll(incoming)
      ..addAll(newer);
  }

  ref
      .read(apiClientProvider)
      .get('/chats/$chatId/messages', query: {'limit': 200})
      .then<void>((json) {
        if (controller.isClosed || seeded) return;
        for (final item in (json['messages'] as List<dynamic>? ?? const [])) {
          final m = item as Map<String, dynamic>;
          byId.putIfAbsent('${m['id']}', () => m);
        }
        seeded = true;
        emit();
      }, onError: (Object _) {
        // The socket snapshot covers it; if that never comes either, the
        // "Connecting…" caption says why.
      });

  final wsSub = ref.watch(realtimeClientProvider).subscribe('chat:$chatId:messages').listen((e) {
    switch (e.type) {
      case RealtimeEventType.snapshot:
        mergeSnapshot(e.data as List<dynamic>? ?? const []);
        seeded = true;
      case RealtimeEventType.upsert:
        upsert(e.data as Map<String, dynamic>);
      case RealtimeEventType.remove:
        if (e.removedId != null) byId.remove(e.removedId);
      case RealtimeEventType.receipts:
        _applyReceipts(byId, e.data as Map<String, dynamic>);
      case RealtimeEventType.error:
        // FORBIDDEN / UNKNOWN_CHANNEL — surface it instead of spinning forever.
        if (!seeded && !controller.isClosed) {
          controller.addError(StateError(e.error ?? 'REALTIME_ERROR'));
        }
        return;
    }
    emit();
  });

  final sentSub = ref.watch(outboxServiceProvider).sentMessages.listen((sent) {
    if (sent.chatId != chatId) return;
    upsert(sent.message);
    seeded = true; // our own accepted message is worth showing on its own
    emit();
  });

  ref.onDispose(() {
    wsSub.cancel();
    sentSub.cancel();
    controller.close();
  });
  return controller.stream;
}, isAutoDispose: true);

/// The live server message list with any still-unsent outbox messages for this
/// chat overlaid as optimistic "sending" bubbles (Phase 9b) — de-duped by
/// clientKey, so a pending bubble vanishes the instant the server confirms the
/// real message (POST response or channel echo, whichever is first). This is
/// what the thread screen watches; chatMessagesProvider stays the pure server
/// stream underneath. Pending bubbles carry `pending: true` (clock icon) and,
/// once the outbox has failed a few times, `failed: true` (red mark, tap to
/// retry) — see outboxFailedAfterAttempts. autoDispose, like everything under
/// it: a keep-alive here pinned the thread's socket channel and its message
/// window for every chat ever opened.
final mergedChatMessagesProvider =
    Provider.family<AsyncValue<List<ChatDoc>>, String>((ref, chatId) {
      final serverAsync = ref.watch(chatMessagesProvider(chatId));
      final pending = ref.watch(pendingMessagesProvider(chatId)).value ?? const [];
      final session = ref.watch(authStateChangesProvider).value;

      return serverAsync.whenData((server) {
        final serverKeys = server
            .map((m) => m.data()['clientKey'])
            .whereType<String>()
            .toSet();
        final result = [...server];
        for (final item in pending) {
          if (serverKeys.contains(item.id)) continue; // already confirmed
          result.add(ChatDoc({
            'id': 'pending-${item.id}',
            'clientKey': item.id,
            'pending': true,
            'failed': item.looksFailed,
            'senderId': session?.uid,
            'senderRole': item.payload['senderRole'],
            'text': item.payload['text'] ?? '',
            'mediaUrl': item.payload['mediaUrl'],
            'mediaType': item.payload['mediaType'],
            'sharedPostId': item.payload['sharedPostId'],
            'sharedStoryId': item.payload['sharedStoryId'],
            'replyToText': item.payload['replyToText'],
            'replyToSenderRole': item.payload['replyToSenderRole'],
            'createdAt':
                DateTime.fromMillisecondsSinceEpoch(item.createdAt).toIso8601String(),
            'deliveredAt': null,
            'readAt': null,
          }));
        }
        return result;
      });
    }, isAutoDispose: true);

/// The other participant's public profile (admin viewing the customer) —
/// one-shot GET /users/:id (name/avatar/phone). Not live; a name rarely
/// changes mid-conversation.
final userDocProvider = FutureProvider.family<Map<String, dynamic>?, String>((
  ref,
  uid,
) async {
  try {
    final json = await ref.watch(apiClientProvider).get('/users/$uid');
    return json['user'] as Map<String, dynamic>?;
  } catch (_) {
    return null;
  }
}, isAutoDispose: true);
