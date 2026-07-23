import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../../services/firestore_service.dart';

/// Total unread chat messages across every conversation for whichever role
/// is currently signed in — drives the Chat tab's nav-bar badge
/// (router.dart's _TabNavBar) and mirrors the same per-chat unreadByUser/
/// unreadByAdmin counters chat_list_screen.dart's rows already show.
///
/// The admin side deliberately reads adminUnreadChatsProvider (a dedicated
/// unread-only query), NOT the windowed adminChatsProvider the list renders:
/// that list is paginated (see adminChatLimitProvider), so summing its loaded
/// page would undercount unreads sitting in not-yet-loaded conversations. The
/// user side has no such pagination, so it stays on userChatsProvider.
final totalUnreadChatCountProvider = Provider<int>((ref) {
  final role = ref.watch(appRoleProvider).value;
  final isAdmin = role == AppRole.admin || role == AppRole.superadmin;
  if (isAdmin) {
    final unread = ref.watch(adminUnreadChatsProvider).value;
    if (unread == null) return 0;
    return unread.fold<int>(
      0,
      (total, doc) => total + (doc.data()['unreadByAdmin'] as int? ?? 0),
    );
  }
  final chats = ref.watch(userChatsProvider).value;
  if (chats == null) return 0;
  return chats.fold<int>(
    0,
    (total, doc) => total + (doc.data()['unreadByUser'] as int? ?? 0),
  );
});

typedef ChatDoc = QueryDocumentSnapshot<Map<String, dynamic>>;

/// Every active store — merged with userChatsProvider in chat_list_screen.dart
/// so a plain user's chat list shows every store by default (tapping one with
/// no prior conversation lazily creates the chat via ChatService.createOrGetChat),
/// not just stores they've already messaged.
final activeStoresProvider = StreamProvider<List<ChatDoc>>((ref) {
  return ref
      .watch(firestoreProvider)
      .collection('stores')
      .where('active', isEqualTo: true)
      .snapshots()
      .map((snap) => snap.docs);
});

/// A plain user's conversations, one per store they've messaged.
final userChatsProvider = StreamProvider<List<ChatDoc>>((ref) {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return Stream.value([]);

  return ref
      .watch(firestoreProvider)
      .collection('chats')
      .where('userId', isEqualTo: user.uid)
      .orderBy('lastMessageAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs);
});

/// How many of a store admin's conversations the inbox currently streams,
/// grown one page at a time as they scroll (chat_list_screen.dart's
/// _AdminChatList drives loadMore). Bounding this is the whole point: the
/// query was previously unbounded, so a store with hundreds of conversations
/// held a live listener over every one and re-delivered the full set to the
/// device on every change. A windowed slice is exactly how a real messaging
/// inbox (WhatsApp/Instagram) subscribes — recent N live, older pages fetched
/// on demand.
class AdminChatLimitNotifier extends Notifier<int> {
  static const pageSize = 40;

  @override
  int build() => pageSize;

  void loadMore() => state += pageSize;
}

final adminChatLimitProvider = NotifierProvider<AdminChatLimitNotifier, int>(
  AdminChatLimitNotifier.new,
);

/// A store admin's conversations, across all stores they manage, windowed to
/// the most-recent [adminChatLimitProvider] by last activity.
/// Not `.family` — a `List<String>` arg has no value equality.
final adminChatsProvider = StreamProvider<List<ChatDoc>>((ref) async* {
  final storeIds = await ref.watch(storeIdsProvider.future);
  if (storeIds.isEmpty) {
    yield [];
    return;
  }
  final limit = ref.watch(adminChatLimitProvider);

  yield* ref
      .watch(firestoreProvider)
      .collection('chats')
      .where('storeId', whereIn: storeIds)
      .orderBy('lastMessageAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((snap) => snap.docs);
});

/// Only the admin's conversations that currently have unread messages —
/// a dedicated real-time query so the nav-bar badge
/// (totalUnreadChatCountProvider) stays exact no matter how little of the
/// windowed adminChatsProvider list is loaded. Naturally small: a chat only
/// carries unreadByAdmin > 0 in the window between a message arriving and the
/// admin opening the thread. Requires the chats (storeId, unreadByAdmin)
/// composite index — see firestore.indexes.json.
final adminUnreadChatsProvider = StreamProvider<List<ChatDoc>>((ref) async* {
  final storeIds = await ref.watch(storeIdsProvider.future);
  if (storeIds.isEmpty) {
    yield [];
    return;
  }

  yield* ref
      .watch(firestoreProvider)
      .collection('chats')
      .where('storeId', whereIn: storeIds)
      .where('unreadByAdmin', isGreaterThan: 0)
      .snapshots()
      .map((snap) => snap.docs);
});

final chatDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((
  ref,
  chatId,
) {
  return ref
      .watch(firestoreProvider)
      .collection('chats')
      .doc(chatId)
      .snapshots()
      .map((snap) => snap.data());
}, isAutoDispose: true);

final chatMessagesProvider = StreamProvider.family<List<ChatDoc>, String>((
  ref,
  chatId,
) {
  return ref
      .watch(firestoreProvider)
      .collection('chats')
      .doc(chatId)
      .collection('messages')
      .orderBy('createdAt')
      // limitToLast, not limit — the latter takes the oldest 200 (since the
      // sort is ascending), so once a thread crosses 200 messages every
      // *new* one would fall outside the window and just never appear for
      // either side. limitToLast keeps the query ascending (still oldest→
      // newest, matching what the ListView below expects) while actually
      // returning the most recent 200.
      .limitToLast(200)
      .snapshots()
      .map((snap) => snap.docs);
}, isAutoDispose: true);

/// Structural twin of `storeDocProvider` — lets the admin side show the
/// customer's name/phone.
final userDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((
  ref,
  uid,
) {
  return ref
      .watch(firestoreProvider)
      .collection('users')
      .doc(uid)
      .snapshots()
      .map((snap) => snap.data());
}, isAutoDispose: true);
