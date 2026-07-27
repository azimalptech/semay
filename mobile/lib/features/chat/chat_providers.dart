import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/json_ext.dart';
import '../../core/outbox.dart';
import '../../core/realtime_client.dart';
import '../../services/auth_service.dart';

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

/// Total unread messages across every conversation for the current role —
/// drives the Chat tab's nav-bar badge.
final totalUnreadChatCountProvider = Provider<int>((ref) {
  final role = ref.watch(appRoleProvider).value;
  final isAdmin = role == AppRole.admin || role == AppRole.superadmin;
  final chats = isAdmin
      ? ref.watch(adminChatsProvider).value
      : ref.watch(userChatsProvider).value;
  if (chats == null) return 0;
  final field = isAdmin ? 'unreadByAdmin' : 'unreadByUser';
  return chats.fold<int>(0, (t, doc) => t + (doc.data()[field] as int? ?? 0));
});

/// Every active store — merged with userChatsProvider in chat_list_screen so a
/// plain user's chat list shows every store by default (tapping one with no
/// prior conversation lazily creates the chat).
final activeStoresProvider = FutureProvider<List<ChatDoc>>((ref) async {
  final json = await ref.watch(apiClientProvider).get('/stores');
  final list = (json['stores'] as List<dynamic>? ?? const []);
  return list.map((e) => ChatDoc(e as Map<String, dynamic>)).toList();
});

/// Maintains a keyed list from a single realtime list-channel's snapshot/
/// upsert/remove events, sorted by last activity, filtered by hide-state.
Stream<List<ChatDoc>> _chatListChannel(
  Ref ref,
  String channel, {
  required bool admin,
}) async* {
  final byId = <String, Map<String, dynamic>>{};

  await for (final e in ref.watch(realtimeClientProvider).subscribe(channel)) {
    switch (e.type) {
      case RealtimeEventType.snapshot:
        byId.clear();
        for (final item in (e.data as List<dynamic>? ?? const [])) {
          final chat = item as Map<String, dynamic>;
          byId[chat['id'] as String] = chat;
        }
      case RealtimeEventType.upsert:
        final chat = e.data as Map<String, dynamic>;
        byId[chat['id'] as String] = chat;
      case RealtimeEventType.remove:
        if (e.removedId != null) byId.remove(e.removedId);
      case RealtimeEventType.error:
        continue;
    }
    final visible = byId.values.where((c) => _visibleFor(c, admin: admin)).toList()
      ..sort(_byLastMessageDesc);
    yield visible.map((c) => ChatDoc(c)).toList();
  }
}

/// A plain user's conversations, live via `user:{uid}:chats`.
final userChatsProvider = StreamProvider<List<ChatDoc>>((ref) async* {
  final session = await ref.watch(authStateChangesProvider.future);
  if (session == null) {
    yield const [];
    return;
  }
  yield* _chatListChannel(ref, 'user:${session.uid}:chats', admin: false);
});

/// A store admin's conversations across every store they manage — one
/// `store:{id}:chats` channel per store, merged client-side (the channel is
/// per-store by design; see docs/07_MIGRATION.md). The server snapshot caps at
/// the most recent 100 per store, replacing the old client-side pagination.
final adminChatsProvider = StreamProvider<List<ChatDoc>>((ref) {
  final controller = StreamController<List<ChatDoc>>();
  final byId = <String, Map<String, dynamic>>{}; // chatId -> chat, all stores
  final subs = <StreamSubscription<dynamic>>[];

  void emit() {
    final list = byId.values.where((c) => _visibleFor(c, admin: true)).toList()
      ..sort(_byLastMessageDesc);
    if (!controller.isClosed) {
      controller.add(list.map((c) => ChatDoc(c)).toList());
    }
  }

  Future<void> start() async {
    final storeIds = await ref.watch(storeIdsProvider.future);
    if (storeIds.isEmpty) {
      emit();
      return;
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
                }
              case RealtimeEventType.upsert:
                final chat = e.data as Map<String, dynamic>;
                byId[chat['id'] as String] = chat;
              case RealtimeEventType.remove:
                if (e.removedId != null) byId.remove(e.removedId);
              case RealtimeEventType.error:
                return;
            }
            emit();
          });
      subs.add(sub);
    }
  }

  start();
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

/// Live message list via `chat:{id}:messages`, oldest-first (the ListView
/// expects ascending; the server sends newest-first, so reverse). The snapshot
/// is the recent window; each new message arrives as an upsert.
final chatMessagesProvider = StreamProvider.family<List<ChatDoc>, String>((
  ref,
  chatId,
) async* {
  final byId = <String, Map<String, dynamic>>{};
  List<ChatDoc> current() {
    final list = byId.values.toList()
      ..sort((a, b) {
        final ai = int.tryParse('${a['id']}') ?? 0;
        final bi = int.tryParse('${b['id']}') ?? 0;
        return ai.compareTo(bi); // ascending: oldest -> newest
      });
    return list.map((m) => ChatDoc(m)).toList();
  }

  await for (final e in ref.watch(realtimeClientProvider).subscribe('chat:$chatId:messages')) {
    switch (e.type) {
      case RealtimeEventType.snapshot:
        byId.clear();
        for (final item in (e.data as List<dynamic>? ?? const [])) {
          final m = item as Map<String, dynamic>;
          byId['${m['id']}'] = m;
        }
      case RealtimeEventType.upsert:
        final m = e.data as Map<String, dynamic>;
        byId['${m['id']}'] = m;
      case RealtimeEventType.remove:
        if (e.removedId != null) byId.remove(e.removedId);
      case RealtimeEventType.error:
        continue;
    }
    yield current();
  }
}, isAutoDispose: true);

/// The live server message list with any still-unsent outbox messages for this
/// chat overlaid as optimistic "sending" bubbles (Phase 9b) — de-duped by
/// clientKey, so a pending bubble vanishes the instant the server echoes the
/// real message back over the channel. This is what the thread screen watches;
/// chatMessagesProvider stays the pure server stream underneath.
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
          if (serverKeys.contains(item.id)) continue; // already echoed
          result.add(ChatDoc({
            'id': 'pending-${item.id}',
            'clientKey': item.id,
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
    });

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
