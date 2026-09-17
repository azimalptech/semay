import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/chat_cache.dart';
import '../../core/json_ext.dart';
import '../../core/outbox.dart';
import '../../core/read_cache.dart';
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
///
/// Unlike the chats themselves this is a plain one-shot REST read with no
/// realtime channel, and the chat list is a page of the always-mounted shell
/// pager — so it is refetched whenever the shell settles back on the Chat tab
/// (see ChatListScreen's listener on settledShellTabProvider). Before that, a
/// store the superadmin activated or deactivated mid-session only appeared or
/// disappeared after a full restart of the app.
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

  /// Cached rows were delivered when they were first seen; record their
  /// counts as the baseline without posting anything.
  void baseline(Map<String, dynamic> chat, {required bool admin}) {
    _prevUnread[chat['id'] as String] = _myUnread(chat, admin: admin);
  }

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

  /// The chat left the list — this side deleted it, which also zeroed my
  /// unread server-side. Its baseline goes with it: the message that brings
  /// the chat back arrives as unread 1, and against a remembered 3 that is
  /// not a rise, so the sender would wait for my read receipt to get their
  /// second tick.
  void forget(String chatId) => _prevUnread.remove(chatId);

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

/// How long the socket gets to answer a list subscribe before the REST copy
/// is fetched as a fallback.
///
/// The fallback exists for one failure only — the socket is open, the
/// subscribe was accepted, and the server never delivers (the dead-bus class
/// in docs/08_OPERATIONS.md §3a), where a fresh install showed an empty chat
/// list for good. Firing it unconditionally made every launch, and every
/// reconnect, pay a `GET /chats` (and one per store for an admin) that the
/// socket snapshot then immediately overwrote — a full chat-list query per
/// launch per user, for a case that almost never happens. Waiting first costs
/// the failure case a few seconds it spends showing "Connecting…" anyway, and
/// costs the normal case nothing. Comfortably longer than a snapshot (a
/// handful of indexed queries, bounded at 10 s by the gateway only in the
/// pathological case) and far shorter than the client's own 25 s stall rule.
const chatListRestSeedGrace = Duration(seconds: 3);

/// Maintains a keyed list from a single realtime list-channel's snapshot/
/// upsert/remove events, sorted by last activity, filtered by hide-state.
/// Paints from the local cache first, so the list is on screen at launch (and
/// offline) before the socket has even connected, and from a REST copy of
/// the same list when the socket is up but its server is not delivering.
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
  final cache = ref.read(chatCacheProvider);
  final client = ref.watch(realtimeClientProvider);
  var live = false; // a server list (snapshot or REST) has replaced the cached seed
  var socketGen = 0; // bumped on every frame the channel delivers

  void emit() {
    final visible = byId.values.where((c) => _visibleFor(c, admin: admin)).toList()
      ..sort(_byLastMessageDesc);
    if (!controller.isClosed) controller.add(visible.map((c) => ChatDoc(c)).toList());
  }

  // A full server list replaces whatever is held. The socket snapshot and
  // the REST answer are the same query (listUserChats), so both land here.
  void replaceAll(List<Map<String, dynamic>> rows) {
    live = true;
    byId.clear();
    for (final chat in rows) {
      byId[chat['id'] as String] = chat;
      delivery.observe(chat, admin: admin);
    }
    unawaited(cache.replaceChats(rows));
    emit();
  }

  // The REST copy (GET /chats), so the list exists when the socket is open
  // but its server delivers nothing — subscribed, no snapshot, no upserts:
  // the dead-Redis class in docs/08_OPERATIONS.md §3a, which on a fresh
  // install with nothing cached showed an empty list for good. The socket
  // supersedes it: a frame that lands while the fetch is in flight means the
  // channel is live and already fresher than this answer, which is then
  // dropped rather than merged over it.
  Future<void> seedFromRest() async {
    final gen = socketGen;
    try {
      final json = await ref.read(apiClientProvider).get('/chats');
      if (controller.isClosed || socketGen != gen) return;
      replaceAll((json['chats'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>());
    } catch (_) {
      // The cache (if any) stays on screen; the snapshot covers it when the
      // socket comes up, and "Connecting…" says why until then.
    }
  }

  // Armed at launch and re-armed on every reconnect (`resyncs`), but only
  // SPENT when the socket has still said nothing by the time it fires — see
  // chatListRestSeedGrace.
  Timer? restSeed;
  void armRestSeed() {
    final gen = socketGen;
    restSeed?.cancel();
    restSeed = Timer(chatListRestSeedGrace, () {
      if (controller.isClosed || socketGen != gen) return;
      unawaited(seedFromRest());
    });
  }

  unawaited(cache.chats().then((rows) {
    if (live || controller.isClosed || rows.isEmpty) return;
    for (final chat in rows) {
      // putIfAbsent: an upsert that beat the cache read is fresher than the
      // cached copy and must not be overwritten by it.
      byId.putIfAbsent(chat['id'] as String, () => chat);
      delivery.baseline(chat, admin: admin);
    }
    emit();
  }));
  armRestSeed();
  final resyncSub = client.resyncs.where((c) => c == channel).listen((_) => armRestSeed());

  final sub = client.subscribe(channel).listen((e) {
    socketGen++;
    switch (e.type) {
      case RealtimeEventType.snapshot:
        replaceAll(
          (e.data as List<dynamic>? ?? const []).cast<Map<String, dynamic>>(),
        );
        return;
      case RealtimeEventType.upsert:
        final chat = e.data as Map<String, dynamic>;
        byId[chat['id'] as String] = chat;
        delivery.observe(chat, admin: admin);
        unawaited(cache.upsertChat(chat));
      case RealtimeEventType.remove:
        if (e.removedId != null) {
          byId.remove(e.removedId);
          delivery.forget(e.removedId!);
          unawaited(cache.removeChat(e.removedId!));
        }
      case RealtimeEventType.receipts:
      case RealtimeEventType.error:
        return;
    }
    emit();
  });

  ref.onDispose(() {
    restSeed?.cancel();
    sub.cancel();
    resyncSub.cancel();
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
  final cache = ref.read(chatCacheProvider);
  final client = ref.watch(realtimeClientProvider);
  final liveStores = <String>{}; // stores whose server list has arrived
  final socketGen = <String, int>{}; // per store — see _chatListChannel

  void emit() {
    final list = byId.values.where((c) => _visibleFor(c, admin: true)).toList()
      ..sort(_byLastMessageDesc);
    if (!controller.isClosed) {
      controller.add(list.map((c) => ChatDoc(c)).toList());
    }
  }

  // Replace just this store's entries — from its snapshot or its REST copy,
  // the same query (listStoreChats) either way.
  void replaceStore(String storeId, List<Map<String, dynamic>> rows) {
    liveStores.add(storeId);
    byId.removeWhere((_, c) => c['storeId'] == storeId);
    for (final chat in rows) {
      byId[chat['id'] as String] = chat;
      delivery.observe(chat, admin: true);
    }
    unawaited(cache.replaceChats(rows, storeId: storeId));
    emit();
  }

  // Same REST fallback and socket-supersedes rule as _chatListChannel, per
  // store (GET /chats?storeId= is the admin form of the same endpoint).
  Future<void> seedFromRest(String storeId) async {
    final gen = socketGen[storeId] ?? 0;
    try {
      final json = await ref
          .read(apiClientProvider)
          .get('/chats', query: {'storeId': storeId});
      if (controller.isClosed || (socketGen[storeId] ?? 0) != gen) return;
      replaceStore(
        storeId,
        (json['chats'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>(),
      );
    } catch (_) {
      // See _chatListChannel.
    }
  }

  // One armed timer per store, on the same grace as _chatListChannel — an
  // admin of four stores used to pay four GET /chats on every launch and
  // every reconnect, and now pays none unless a store's channel really does
  // go silent.
  final restSeeds = <String, Timer>{};
  void armRestSeed(String storeId) {
    final gen = socketGen[storeId] ?? 0;
    restSeeds.remove(storeId)?.cancel();
    restSeeds[storeId] = Timer(chatListRestSeedGrace, () {
      if (controller.isClosed || (socketGen[storeId] ?? 0) != gen) return;
      unawaited(seedFromRest(storeId));
    });
  }

  if (storeIds.isEmpty) {
    emit();
  } else {
    unawaited(cache.chats().then((rows) {
      if (controller.isClosed) return;
      var added = false;
      for (final chat in rows) {
        final storeId = chat['storeId'] as String?;
        if (storeId == null || !storeIds.contains(storeId) || liveStores.contains(storeId)) continue;
        byId.putIfAbsent(chat['id'] as String, () => chat); // see _chatListChannel
        delivery.baseline(chat, admin: true);
        added = true;
      }
      if (added) emit();
    }));
  }
  for (final storeId in storeIds) {
    final channel = 'store:$storeId:chats';
    armRestSeed(storeId);
    subs.add(
      client.resyncs.where((c) => c == channel).listen((_) => armRestSeed(storeId)),
    );
    final sub = client.subscribe(channel).listen((e) {
          socketGen[storeId] = (socketGen[storeId] ?? 0) + 1;
          switch (e.type) {
            case RealtimeEventType.snapshot:
              replaceStore(
                storeId,
                (e.data as List<dynamic>? ?? const []).cast<Map<String, dynamic>>(),
              );
              return;
            case RealtimeEventType.upsert:
              final chat = e.data as Map<String, dynamic>;
              byId[chat['id'] as String] = chat;
              delivery.observe(chat, admin: true);
              unawaited(cache.upsertChat(chat));
            case RealtimeEventType.remove:
              if (e.removedId != null) {
                byId.remove(e.removedId);
                delivery.forget(e.removedId!);
                unawaited(cache.removeChat(e.removedId!));
              }
            case RealtimeEventType.receipts:
            case RealtimeEventType.error:
              return;
          }
          emit();
        });
    subs.add(sub);
  }

  ref.onDispose(() {
    for (final t in restSeeds.values) {
      t.cancel();
    }
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
/// Three sources started at once, freshest wins: the cached copy (so the
/// thread header knows the store/customer and which side the viewer is on
/// even offline), a REST fetch, and the socket's snapshot/upserts. Started
/// concurrently rather than in sequence so a slow REST answer (up to the
/// 30 s timeout on a bad link) never delays the socket subscription — and
/// with it the typing/unread events the thread screen keys on.
final chatDocProvider = StreamProvider.family<Map<String, dynamic>?, String>((
  ref,
  chatId,
) {
  final controller = StreamController<Map<String, dynamic>?>();
  final cache = ref.read(chatCacheProvider);
  var wsLive = false; // the socket has spoken — REST/cache can no longer regress it
  var restDone = false;
  var shown = false;

  void emit(Map<String, dynamic>? chat, {required bool persist}) {
    shown = true;
    if (!controller.isClosed) controller.add(chat);
    if (persist && chat != null) unawaited(cache.upsertChat(chat));
  }

  unawaited(cache.chat(chatId).then((cached) {
    if (controller.isClosed || wsLive || restDone || cached == null) return;
    emit(cached, persist: false);
  }));
  unawaited(
    ref.read(apiClientProvider).get('/chats/$chatId').then<void>((json) {
      restDone = true;
      if (controller.isClosed || wsLive) return;
      emit(json['chat'] as Map<String, dynamic>?, persist: true);
    }, onError: (Object _) {
      restDone = true;
      // Nothing to show at all: say so, rather than spinning until the
      // socket (which may be the thing that is down) answers.
      if (!controller.isClosed && !wsLive && !shown) controller.add(null);
    }),
  );
  final sub = ref.watch(realtimeClientProvider).subscribe('chat:$chatId').listen((e) {
    if (e.type == RealtimeEventType.snapshot || e.type == RealtimeEventType.upsert) {
      wsLive = true;
      emit(e.data as Map<String, dynamic>?, persist: true);
    }
  });

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });
  return controller.stream;
}, isAutoDispose: true);

int _messageId(Map<String, dynamic> m) => int.tryParse('${m['id']}') ?? 0;

/// [m] as this side may see it once its history cutoff is [cutoff]: a quote of
/// a row at or below it is blanked. The other side can still reply to a
/// message this side deleted, and the reply carries that message's text —
/// the server projects the same mask over the thread window and paging
/// (listMessages), but the live upsert on `chat:{id}:messages` is one frame
/// for both sides, and a cached row may predate the cutoff being known, so
/// it is applied here as well. Returns [m] itself when nothing is masked.
Map<String, dynamic> _withoutHiddenQuote(Map<String, dynamic> m, int cutoff) {
  final quoted = int.tryParse('${m['replyToMessageId']}');
  if (quoted == null || quoted > cutoff) return m;
  return {...m, 'replyToMessageId': null, 'replyToText': null, 'replyToSenderRole': null};
}

/// Applies a `receipts` roll-up the way the server's updateMany did: every
/// message from `senderRole` up to `upToMessageId` (the newest row the server
/// actually stamped — a message that arrived over the socket a moment before
/// the receipt was NOT in that set, and stamping it would show "Seen" for a
/// message nobody has seen) and above `fromMessageId` (the reader's history
/// cutoff — rows at or below it are invisible to them, so they were not
/// stamped and must not show as seen here either) that is still missing the
/// stamp gets it. Copies rather than mutating, so lists already handed to the
/// UI are never edited under it. Returns the keys it changed.
///
/// A NULL `upToMessageId` means the server stamped no row at all, and the only
/// correct reading of it is "change nothing". Treating it as "no upper bound"
/// stamped the whole window — including a message that reached this socket a
/// moment before the receipt — so bubbles nobody had opened flipped to the
/// blue double tick, and the thread cache persisted that lie across a
/// relaunch. The server can genuinely send it: markReceipts publishes whenever
/// `msgs.count + unreadCleared > 0`, so a read receipt that stamped no message
/// but cleared a non-zero unread counter (a `sendMessage` committing between
/// its two updateMany statements) carries a null bound.
List<String> _applyReceipts(Map<String, Map<String, dynamic>> byId, Map<String, dynamic> receipt) {
  final role = receipt['senderRole'];
  final status = receipt['status'];
  final at = receipt['at'];
  final upTo = int.tryParse('${receipt['upToMessageId']}');
  if (upTo == null) return const <String>[];
  final from = int.tryParse('${receipt['fromMessageId']}');
  final changed = <String>[];
  for (final entry in byId.entries.toList()) {
    final m = entry.value;
    if (m['senderRole'] != role) continue;
    final id = _messageId(m);
    if (id > upTo) continue;
    if (from != null && id <= from) continue;
    if (status == 'read') {
      if (m['readAt'] != null) continue;
      byId[entry.key] = {...m, 'readAt': at, 'deliveredAt': at};
    } else {
      if (m['deliveredAt'] != null) continue;
      byId[entry.key] = {...m, 'deliveredAt': at};
    }
    changed.add(entry.key);
  }
  return changed;
}

/// What the thread screen renders, plus the paging flags it needs.
class ChatMessagesState {
  const ChatMessagesState({
    this.messages = const [],
    this.seeded = false,
    this.hasMore = true,
    this.loadingOlder = false,
    this.error,
  });

  /// Oldest first (the reversed ListView shows the last element at the bottom).
  final List<ChatDoc> messages;

  /// Something worth painting has arrived — the local cache, the REST seed,
  /// the socket snapshot, or our own accepted message. Until then the screen
  /// shows a spinner.
  final bool seeded;

  /// Older history may exist beyond the oldest message held — false once a
  /// page comes back short or the server's window was smaller than a page.
  final bool hasMore;
  final bool loadingOlder;

  /// A channel error (FORBIDDEN…) before anything could be shown.
  final String? error;
}

/// The messages of one thread, oldest-first, fed by four sources and merged
/// by message id (monotonic BIGINTs, so "newer" is one comparison):
///
///  * the local cache (chat_cache.dart) — instant paint, works offline;
///  * a REST fetch of the latest window — fastest fresh paint, the thread
///    still loads when the socket can't connect but REST can, and repeated
///    on every socket reconnect (RealtimeClient.resyncs) because the
///    snapshot a reconnect should bring may never come;
///  * the socket (snapshot → upserts/receipts), authoritative once it lands;
///  * the outbox: the moment the server accepts one of OUR messages (POST
///    response) that row lands here directly rather than waiting for its echo
///    — see SentMessage for the vanishing-bubble bug that fixed.
///
/// Scroll-back is [loadOlder]: pages before the oldest held message, 50 at a
/// time, merged in and cached (the cache keeps the newest 500 per thread).
/// Every change is written through to the cache.
///
/// Deleting the chat (ChatService.hideChat) makes everything sent so far
/// invisible to this side, server-side, by message id — the chat doc's
/// hiddenBy*UpToId. That cutoff is applied here too ([_applyCutoff]), because
/// the cache and an in-memory window can both hold rows the server will never
/// return again, and neither may resurrect them.
class ChatMessagesNotifier extends Notifier<ChatMessagesState> {
  ChatMessagesNotifier(this.chatId);

  final String chatId;

  /// The server's snapshot / REST window. A window shorter than this is the
  /// whole thread — nothing older to page.
  static const _windowSize = 200;
  static const _pageSize = 50;

  final _byId = <String, Map<String, dynamic>>{};
  StreamSubscription<RealtimeEvent>? _wsSub;
  StreamSubscription<String>? _resyncSub;
  StreamSubscription<SentMessage>? _sentSub;
  bool _disposed = false;
  bool _seeded = false;
  bool _authoritative = false; // REST seed or socket snapshot has landed
  int _socketGen = 0; // bumped on every frame the thread channel delivers
  bool _hasMore = true;
  bool _loadingOlder = false;
  String? _error;
  int? _cutoff; // this side's history cutoff (message id), once known

  ChatCache get _cache => ref.read(chatCacheProvider);

  @override
  ChatMessagesState build() {
    _byId.clear();
    _disposed = false;
    _seeded = false;
    _authoritative = false;
    _socketGen = 0;
    _hasMore = true;
    _loadingOlder = false;
    _error = null;
    _cutoff = null;
    ref.onDispose(() {
      _disposed = true;
      _wsSub?.cancel();
      _resyncSub?.cancel();
      _sentSub?.cancel();
    });
    // The cutoff comes from the chat doc, for whichever side this account is
    // on — the customer if it owns the chat, the store side otherwise, which
    // is exactly the server's resolveChatSide. Listened to rather than read
    // once: a delete on this account's other device reaches an open thread as
    // a chat:{id} upsert, and its rows must go the same way.
    final uid = ref.read(authStateChangesProvider).value?.uid;
    ref.listen(chatDocProvider(chatId), (_, next) {
      final chat = next.value;
      if (chat == null) return;
      final key = chat['userId'] == uid ? 'hiddenByUserUpToId' : 'hiddenByAdminUpToId';
      final cutoff = int.tryParse('${chat[key]}');
      if (cutoff != null) _applyCutoff(cutoff);
    }, fireImmediately: true);
    unawaited(_seedFromCache());
    unawaited(_seedFromRest());
    _listenSocket();
    _listenResyncs();
    _listenOutbox();
    return const ChatMessagesState();
  }

  /// Everything at or below [cutoff] is gone for this side. Whatever arrived
  /// before the cutoff was known — the cache seed, a stale window — is dropped
  /// now; whatever arrives later is refused at the door ([_upsert],
  /// [_seedFromCache]); and the on-disk copy is pruned so a relaunch cannot
  /// paint it either.
  void _applyCutoff(int cutoff) {
    if (_cutoff != null && cutoff <= _cutoff!) return;
    _cutoff = cutoff;
    unawaited(_cache.pruneMessagesUpTo(chatId, cutoff));
    final before = _byId.length;
    _byId.removeWhere((_, m) => _messageId(m) <= cutoff);
    // Rows that stay may still quote rows that just went (see
    // _withoutHiddenQuote); the cache learns the masked copy too.
    final unquoted = <Map<String, dynamic>>[];
    for (final entry in _byId.entries.toList()) {
      final masked = _withoutHiddenQuote(entry.value, cutoff);
      if (identical(masked, entry.value)) continue;
      _byId[entry.key] = masked;
      unquoted.add(masked);
    }
    if (unquoted.isNotEmpty) unawaited(_cache.upsertMessages(chatId, unquoted));
    if (_byId.length != before || unquoted.isNotEmpty) _publish();
  }

  List<ChatDoc> _current() {
    final list = _byId.values.toList()
      ..sort((a, b) => _messageId(a).compareTo(_messageId(b))); // oldest -> newest
    return list.map((m) => ChatDoc(m)).toList();
  }

  void _publish() {
    if (_disposed) return;
    state = ChatMessagesState(
      messages: _seeded ? _current() : const [],
      seeded: _seeded,
      hasMore: _hasMore,
      loadingOlder: _loadingOlder,
      error: _error,
    );
  }

  /// A late arrival must never regress a stamp already applied from a
  /// receipts event — the POST response can land after the socket echo.
  /// Returns false when the row is below this side's cutoff and was refused.
  bool _upsert(Map<String, dynamic> row) {
    final cutoff = _cutoff;
    if (cutoff != null && _messageId(row) <= cutoff) return false;
    final m = cutoff == null ? row : _withoutHiddenQuote(row, cutoff);
    final id = '${m['id']}';
    final existing = _byId[id];
    if (existing == null) {
      _byId[id] = m;
      return true;
    }
    _byId[id] = {
      ...m,
      'deliveredAt': m['deliveredAt'] ?? existing['deliveredAt'],
      'readAt': m['readAt'] ?? existing['readAt'],
    };
    return true;
  }

  /// Merges an authoritative window (the socket snapshot or the REST seed):
  /// inside its id range the server is right — rows it lacks are dropped —
  /// and newer rows outside it are kept: an upsert (or our own POST response)
  /// that raced the query. Older rows are kept only while the window is full
  /// (paged history it never covered). A window shorter than the server's
  /// limit — [complete] — IS the entire thread this side may see, so anything
  /// older held here (the cache seed, above all) is precisely what the server
  /// chose not to return, i.e. history below a delete's cutoff, and must not
  /// be painted around it.
  void _mergeWindow(List<Map<String, dynamic>> rows, {required bool complete}) {
    if (rows.isEmpty) {
      _byId.clear();
      return;
    }
    var minId = 1 << 62;
    var maxId = 0;
    for (final m in rows) {
      final id = _messageId(m);
      minId = min(minId, id);
      maxId = max(maxId, id);
    }
    _byId.removeWhere((_, m) {
      final id = _messageId(m);
      return id <= maxId && (complete || id >= minId);
    });
    for (final m in rows) {
      _byId['${m['id']}'] = m;
    }
  }

  Future<void> _seedFromCache() async {
    final rows = await _cache.messages(chatId);
    if (_disposed || _authoritative || rows.isEmpty) return;
    // The prune in _applyCutoff may not have reached the disk copy yet.
    final cutoff = _cutoff;
    for (final m in rows) {
      if (cutoff != null && _messageId(m) <= cutoff) continue;
      _byId.putIfAbsent('${m['id']}', () => cutoff == null ? m : _withoutHiddenQuote(m, cutoff));
    }
    if (_byId.isEmpty) return; // nothing survived — let the server seed
    _seeded = true;
    _publish();
  }

  /// The latest window over REST. [resync] = a socket reconnect (see
  /// _listenResyncs) rather than the open: the first seed defers to a
  /// snapshot that has already landed, a re-seed to any frame that arrived
  /// while it was in flight — either way the socket has spoken since and
  /// holds the fresher state (a receipts stamp this answer would undo, a
  /// message it lacks), so the answer is dropped.
  Future<void> _seedFromRest({bool resync = false}) async {
    final gen = _socketGen;
    try {
      final json = await ref
          .read(apiClientProvider)
          .get('/chats/$chatId/messages', query: {'limit': _windowSize});
      if (_disposed) return;
      if (resync ? _socketGen != gen : _authoritative) return;
      final rows = (json['messages'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
      _mergeWindow(rows, complete: rows.length < _windowSize);
      _authoritative = true;
      _seeded = true;
      if (rows.length < _windowSize) _hasMore = false;
      unawaited(_cache.upsertMessages(chatId, rows));
      _publish();
    } catch (_) {
      // The socket snapshot covers it; if that never comes either, the cache
      // (if any) stays on screen and the "Connecting…" caption says why.
    }
  }

  /// A reconnect re-subscribes the channel and should bring a snapshot. When
  /// it does not — the server's bus is down, which is why the client
  /// reconnected in the first place — the REST window is the only source of
  /// what was missed, so it is fetched again. One request per reconnect.
  void _listenResyncs() {
    _resyncSub = ref
        .read(realtimeClientProvider)
        .resyncs
        .where((c) => c == 'chat:$chatId:messages')
        .listen((_) => _seedFromRest(resync: true));
  }

  void _listenSocket() {
    _wsSub = ref.read(realtimeClientProvider).subscribe('chat:$chatId:messages').listen((e) {
      _socketGen++;
      switch (e.type) {
        case RealtimeEventType.snapshot:
          final rows = (e.data as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
          _mergeWindow(rows, complete: rows.length < _windowSize);
          _authoritative = true;
          _seeded = true;
          _error = null;
          if (rows.length < _windowSize) _hasMore = false;
          unawaited(_cache.upsertMessages(chatId, rows));
        case RealtimeEventType.upsert:
          final m = e.data as Map<String, dynamic>;
          if (_upsert(m)) {
            unawaited(_cache.upsertMessages(chatId, [_byId['${m['id']}']!]));
          }
        case RealtimeEventType.remove:
          final id = e.removedId;
          if (id != null) {
            _byId.remove(id);
            unawaited(_cache.removeMessage(chatId, id));
          }
        case RealtimeEventType.receipts:
          final changed = _applyReceipts(_byId, e.data as Map<String, dynamic>);
          if (changed.isNotEmpty) {
            unawaited(_cache.upsertMessages(chatId, changed.map((k) => _byId[k]!)));
          }
        case RealtimeEventType.error:
          // FORBIDDEN / UNKNOWN_CHANNEL — surface it instead of spinning forever.
          if (!_seeded) {
            _error = e.error ?? 'REALTIME_ERROR';
            _publish();
          }
          return;
      }
      _publish();
    });
  }

  void _listenOutbox() {
    _sentSub = ref.read(outboxServiceProvider).sentMessages.listen((sent) {
      if (sent.chatId != chatId) return;
      if (!_upsert(sent.message)) return;
      _seeded = true; // our own accepted message is worth showing on its own
      unawaited(_cache.upsertMessages(chatId, [_byId['${sent.message['id']}']!]));
      _publish();
    });
  }

  /// Scroll-back: one page of messages older than the oldest held.
  Future<void> loadOlder() async {
    if (_disposed || _loadingOlder || !_hasMore || !_seeded || _byId.isEmpty) return;
    _loadingOlder = true;
    _publish();
    final oldest = _byId.values.map(_messageId).reduce(min);
    try {
      final json = await ref.read(apiClientProvider).get(
        '/chats/$chatId/messages',
        query: {'before': '$oldest', 'limit': _pageSize},
      );
      if (_disposed) return;
      final rows = (json['messages'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
      for (final m in rows) {
        _byId.putIfAbsent('${m['id']}', () => m);
      }
      _hasMore = rows.length >= _pageSize;
      unawaited(_cache.upsertMessages(chatId, rows));
    } catch (_) {
      // Leave hasMore as it was — the next scroll to the top retries.
    } finally {
      if (!_disposed) {
        _loadingOlder = false;
        _publish();
      }
    }
  }
}

final chatMessagesProvider =
    NotifierProvider.family<ChatMessagesNotifier, ChatMessagesState, String>(
      ChatMessagesNotifier.new,
      isAutoDispose: true,
    );

/// The live server message list with any still-unsent outbox messages for this
/// chat overlaid as optimistic "sending" bubbles (Phase 9b) — de-duped by
/// clientKey, so a pending bubble vanishes the instant the server confirms the
/// real message (POST response or channel echo, whichever is first). This is
/// what the thread screen watches; chatMessagesProvider stays the pure server
/// state underneath. Pending bubbles carry `pending: true` (clock icon), a
/// `localMediaPath` for a photo/video still uploading, and, once the outbox
/// has failed a few times, `failed: true` (red mark, tap to retry) — see
/// outboxFailedAfterAttempts. autoDispose, like everything under it: a
/// keep-alive here pinned the thread's socket channel and its message window
/// for every chat ever opened.
final mergedChatMessagesProvider =
    Provider.family<AsyncValue<List<ChatDoc>>, String>((ref, chatId) {
      final thread = ref.watch(chatMessagesProvider(chatId));
      final pending = ref.watch(pendingMessagesProvider(chatId)).value ?? const [];
      final session = ref.watch(authStateChangesProvider).value;

      if (!thread.seeded) {
        if (thread.error != null) {
          return AsyncValue.error(StateError(thread.error!), StackTrace.current);
        }
        return const AsyncValue.loading();
      }

      final serverKeys = thread.messages
          .map((m) => m.data()['clientKey'])
          .whereType<String>()
          .toSet();
      final result = [...thread.messages];
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
          'localMediaPath': item.payload['localMediaPath'],
          'sharedPostId': item.payload['sharedPostId'],
          'sharedStoryId': item.payload['sharedStoryId'],
          'replyToText': item.payload['replyToText'],
          'replyToSenderRole': item.payload['replyToSenderRole'],
          // Same wire shape as a server row (UTC, trailing Z) so parseTimestamp
          // localises pending and confirmed bubbles identically — a naive local
          // string here disagreed with confirmed rows by the zone offset and
          // could put a spurious date divider between the two near midnight.
          'createdAt': DateTime.fromMillisecondsSinceEpoch(
            item.createdAt,
            isUtc: true,
          ).toIso8601String(),
          'deliveredAt': null,
          'readAt': null,
        }));
      }
      return AsyncValue.data(result);
    }, isAutoDispose: true);

/// The other participant's public profile (admin viewing the customer) —
/// one-shot GET /users/:id (name/avatar/phone), remembered in the read cache so
/// the thread header and chat list still show the name offline. Not live; a
/// name rarely changes mid-conversation.
final userDocProvider = FutureProvider.family<Map<String, dynamic>?, String>((
  ref,
  uid,
) async {
  final cache = ref.read(readCacheProvider);
  final cacheKey = 'user:$uid:doc';
  try {
    final json = await ref.watch(apiClientProvider).get('/users/$uid');
    final user = json['user'] as Map<String, dynamic>?;
    if (user != null) await cache.writeList(cacheKey, [user]);
    return user;
  } catch (_) {
    final cached = await cache.readList(cacheKey);
    return cached == null || cached.isEmpty ? null : cached.first;
  }
}, isAutoDispose: true);
