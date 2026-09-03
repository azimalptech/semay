# Firestore Data Model

Collection paths and document shapes. `→` marks a subcollection.

## `users/{uid}`
```jsonc
{
  "phone": "+99362123456",
  "name": "Aylar",
  "avatarUrl": "",
  "role": "user",            // "user" | "admin" | "superadmin"  (mirrored in custom claims)
  "storeIds": [],             // populated only if role == "admin"
  "fcmTokens": ["..."],
  "language": "tk",           // "tk" | "ru" — Settings screen selector (Figma). UI selector only for
                               // now; no translated strings wired up yet — see Open Items §7.7.
  "darkMode": false,          // Settings screen toggle — same cross-device-persisted pattern as
                               // language, absent/false = light.
  "activeChatId": null,       // <chatId> | null — the chat thread currently open on this device, set/
                               // cleared by ChatThreadScreen (chat_service.dart's setActiveChat) on
                               // mount/dispose and app foreground/background. DIAGNOSTIC HINT ONLY
                               // since the chat-reliability pass (docs/07_MIGRATION.md Phase 9c):
                               // the server used to skip the push AND the unread increment when this
                               // matched, but a killed app / crash / PATCH lost to bad signal left it
                               // stuck and that chat then never badged or notified again. The
                               // suppression now lives on the device (notification_service.dart's
                               // in-app banner check); sendMessage counts and pushes regardless.
  "createdAt": "<timestamp>"
}
```

## `stores/{storeId}`
```jsonc
{
  "name": "SeMay",
  "tagline": "Feel Beautiful, Always. ✨",   // from Store Detail screen
  "avatarUrl": "",
  "coverUrl": "",
  "phone": "+99362123456",
  "address": "Ashgabat, Bitaraplyk shayoly 142-nji jayy",
  "geopoint": null,                          // optional, if map display is ever needed
  "adminIds": ["uid1", "uid2"],               // multiple admins confirmed
  "postsCount": 14,                           // denormalized, updated by Cloud Function
  "reelsCount": 23,                           // denormalized
  "createdBy": "superadminUid",
  "createdAt": "<timestamp>",
  "active": true,
  "leaderboardOrder": 0,    // superadmin-controlled tab order on the leaderboard screen (see
                            // stores/{storeId}/leaderboard above) — not queried with a Firestore
                            // orderBy (older stores predate this field, which would silently drop
                            // them from the result set); the client sorts in memory instead, missing
                            // values sorted last. Set from the Super Admin web panel's leaderboard
                            // page, normalized to sequential integers on every reorder.
  "campaignImageUrl": "https://... | null", // this store's 3x2 prize banner, shown under this
                                             // store's leaderboard tab. Set from the Super Admin web
                                             // panel (per store). null/absent — banner not shown, no
                                             // placeholder space reserved.
  "campaignStartAt": "<timestamp> | null"   // Only this store's orders at/after this moment count
                                             // toward this store's leaderboard. Each store runs its
                                             // own independent campaign — this is NOT a global
                                             // setting. null/absent — no campaign configured yet for
                                             // this store, so its leaderboard reads as empty, not
                                             // "everything ever". Set via the
                                             // setLeaderboardCampaignStart callable (storeId +
                                             // startAtMillis), which also recomputes that one store's
                                             // stores/{storeId}/leaderboard/* docs from scratch against
                                             // the new cutoff — changing the date isn't just a filter
                                             // on future orders, past ones on/after the new date get
                                             // folded back in too. Superadmin-only: firestore.rules
                                             // excludes campaignStartAt/campaignImageUrl (and
                                             // leaderboardOrder) from the fields a store's own admins
                                             // can write on their store doc.
}
```

## `posts/{postId}`
```jsonc
{
  "storeId": "storeId1",
  "type": "image",             // "image" | "carousel" | "reel"
  "mediaUrls": ["url1", "url2"],  // 1 item for image/reel, 2+ for carousel
  "thumbnailUrl": "",           // for reels
  "caption": "New arrivals! 💅",
  "price": 150,                 // number | null — optional, set from the composer's price field
                                 // (under caption, "Ýazgy"). Not required to publish; the composer
                                 // shows a Skip/Go back confirm dialog at publish time if left empty.
                                 // Displayed on its own line under the caption, formatted as
                                 // "<number> TMT".
  "likesCount": 0,
  "savesCount": 0,
  "viewsCount": 0,               // denormalized unique-viewer count — see posts/{postId}/views below.
                                  // Detail/full-view only; feed scrolling never counts.
  "sentCount": 0,                 // denormalized unique-sender count — see posts/{postId}/sent below.
  "sharesCount": 0,                // denormalized unique-sharer count — see posts/{postId}/shares below.
  "createdAt": "<timestamp>"
}
```
- `posts/{postId}/likes/{uid}` → `{ createdAt }` (existence = liked)
- `posts/{postId}/views/{uid}` → `{ viewedAt }` — unique-viewer record, doc id = uid so re-viewing
  can't inflate the count (mirrors `stories/{storyId}/views/{uid}`). Written by
  `PostsService.recordView` only from the post/reel **detail** view (`ImagePostDetailContent`,
  `ReelPlayerView`), triggered after a 2s dwell timer, OR immediately on liking the post, OR
  immediately on a pinch-zoom gesture — never from feed scrolling. `onViewCreated` (create-only
  trigger, since these docs are never updated/deleted) increments `posts/{postId}.viewsCount`.
- `posts/{postId}/sent/{uid}` → `{ sentAt }` — unique-sender record, same doc-id-per-uid shape as
  `views` above: the same person sending this post to chat more than once still counts once.
  Written by `PostsService.recordSent`, called only after the underlying chat message has actually
  been sent successfully (`send_to_chat_sheet.dart`'s `_send`/`_sendTo`, both post-`sendMessage`) —
  not from the send icon's `onTap` itself, so cancelling the compose sheet without sending records
  nothing. `onSentCreated` increments `posts/{postId}.sentCount`.
- `posts/{postId}/shares/{uid}` → `{ sharedAt }` — same shape/rationale as `sent` above, for the
  native OS share sheet. Written by `PostsService.shareAndRecord`, only when the share sheet's
  result is `ShareResultStatus.success` (not `dismissed`/`unavailable`) — so opening then cancelling
  the share sheet records nothing. `onShareCreated` increments `posts/{postId}.sharesCount`.

No comments feature — the "send" icon next to the like count (Figma post-card action row) shares the
post into an existing chat, it doesn't open a comment thread. Confirmed by explicit product correction;
if comments are wanted later this is new scope, not a restore of removed code (the old
`posts/{postId}/comments` subcollection, `commentsCount`, and `onCommentWrite` trigger were deleted).

## `users/{uid}/saved/{postId}`
`{ createdAt }` — existence = saved/favorited. (Kept under the user, not the post, so "My Saved" queries
are a single collection read.)

## `users/{uid}/liked/{postId}`
`{ createdAt }` — existence = liked, denormalized copy of `posts/{postId}/likes/{uid}` written in the same
batch as `toggleLike` (same rationale as `saved`: a single collection read for the Profile "Liked" list,
instead of a fan-out query across every post's `likes` subcollection).

## `users/{uid}/storySeen/{storeId}`
`{ seenAt }` — written when the user watches a store's story sequence through to the end. A store's ring
on the Homepage renders as "seen" (muted border, sorted last) when `seenAt >=` that store's latest
active story `createdAt`; any newer story flips the ring back to unseen automatically.

## `stories/{storyId}`
```jsonc
{
  "storeId": "storeId1",
  "mediaUrl": "",
  "mediaType": "video",         // "image" | "video"
  "createdAt": "<timestamp>",
  "expiresAt": "<timestamp>"    // createdAt + 24h — ASSUMPTION, confirm in Open Items
}
```
- `stories/{storyId}/views/{uid}`: `{ viewedAt }` — unique-viewer record written when that story
  starts playing for a signed-in viewer (doc id = uid, so rewatching can't inflate the count).
  Collection size = the "seen by N" count shown to the owning store's admin in the story viewer.

## `chats/{chatId}`
`chatId` = deterministic `${userId}_${storeId}` so there's exactly one thread per user↔store pair.
```jsonc
{
  "userId": "uid",
  "storeId": "storeId1",
  "lastMessageText": "...",        // absent until the first real message — ChatService.createOrGetChat
  "lastMessageAt": "<timestamp>",  // deliberately doesn't stamp these at creation (see its comment), so
                                    // opening an empty thread doesn't sort it above chats with real
                                    // history; onMessageCreated sets both the moment a message lands.
                                    // userChatsProvider/adminChatsProvider orderBy this field, and
                                    // Firestore excludes docs missing it — an empty chat just doesn't
                                    // show up in either "recent conversations" query.
  "unreadByUser": 0,
  "unreadByAdmin": 0,
  "typingUserAt": null,         // heartbeat timestamp while the user is composing; the admin side
  "typingAdminAt": null,        // shows "typing…" while it's <5s old (and vice versa). Cleared on send.
  "hiddenByUserAt": null,       // <timestamp> | null — per-side "delete from my list" soft-hide
  "hiddenByAdminAt": null,      // (ChatService.hideChat, swipe-left-to-delete on the chat list). The
                                 // thread stays fully intact for the other party; the deleter's list
                                 // just filters it out (chat_list_screen.dart's _isHiddenForSide) as
                                 // long as lastMessageAt <= this stamp. A newer message bumps
                                 // lastMessageAt past it, so the chat reappears automatically. hideChat
                                 // also zeroes that side's unread counter so the nav badge doesn't keep
                                 // counting a dismissed chat. NOT a hard delete — messages/order
                                 // history are never removed.
  "mutedByUser": false,         // per-chat notification mute, set from the thread's own mute toggle
  "mutedByAdmin": false         // (chat_thread_screen.dart) — suppresses only the FCM push
                                 // (onMessageCreated), not the message itself or the unread counter.
                                 // One shared flag per side, same granularity as typingAdminAt/
                                 // unreadByAdmin — a store with several admins shares one mute state,
                                 // not one per admin.
}
```
The unread counters (`unreadByUser`/`unreadByAdmin`) still drive the Chat tab's badge, but per-message
read receipts (ticks + "Seen HH:MM") are tracked per-message below, not derived from them.
- `chats/{chatId}/messages/{messageId}`:
```jsonc
{
  "senderId": "uid",
  "senderRole": "user",          // "user" | "admin"
  "text": "Do you have this in size M?",
  "mediaUrl": null,
  "mediaType": null,               // "image" | "video" | null — set only alongside mediaUrl for a raw
                                    // gallery attachment (Storage path /chats/{chatId}/{file}); null
                                    // for sharedPostId/sharedStoryId messages, which use their own
                                    // resolution instead (see below).
  "orderId": null,                // set only on the system message generated by "kabul edildi"
  "sharedPostId": null,            // set only on a "send to chat" share — the shared post's id.
                                    // mediaUrl carries that post's preview image URL (reels use their
                                    // thumbnail); text carries its caption (may be empty).
  "sharedStoryId": null,           // set only on a story reply — the story being replied to; mediaUrl
                                    // carries the story image for image stories (null for video ones).
  "replyToMessageId": null,        // set only on a quoted reply (long-press a bubble -> Reply) — the
                                    // original message's id within this same subcollection.
  "replyToText": null,             // denormalized snippet of the replied-to message (its text, or an
                                    // emoji placeholder for a media-only/shared-post message) — captured
                                    // at send time, not a live reference, so the quote still renders even
                                    // if the original message is later deleted.
  "replyToSenderRole": null,       // "user" | "admin" | null — which side sent the replied-to message,
                                    // used to render "You" vs the counterpart's name above the quote.
  "createdAt": "<timestamp>",
  "deliveredAt": null,             // <timestamp> | null — set by the *recipient's* client the moment
                                    // their device receives this message, by whichever path is first:
                                    // the realtime chat-list channel (chat_providers.dart's
                                    // _DeliveryMarker posts a delivered receipt when the chat's unread
                                    // for this side rises — works with push disabled/refused/muted),
                                    // the FCM background/foreground handler (notification_service.dart
                                    // — reached even with the app closed, via the push's chatId data
                                    // payload) or, if they already have the thread open, the same
                                    // moment as readAt below. Single check (sent only) vs double gray
                                    // check (delivered) in the UI. The stamp reaches the other side as
                                    // a `receipts` realtime event, not a re-sent message list.
  "readAt": null                   // <timestamp> | null — set by the recipient's client when they
                                    // actually open/view the thread (chat_service.dart's
                                    // markMessagesRead). Double *blue* check + "Seen HH:MM" under the
                                    // newest message once set. Firestore rules restrict both fields to
                                    // being written only by whichever side did *not* send the message.
}
```

## `orders/{orderId}`
```jsonc
{
  "storeId": "storeId1",
  "adminId": "uidOfAdminWhoAccepted",
  "userId": "uid",
  "chatId": "uid_storeId1",
  "itemQuantity": 2,
  "userPhone": "+993...",            // auto-filled client-side from users/{userId}.phone, not typed
  "status": "accepted",             // always "accepted" — set once at creation, never transitions.
                                     // The Store Admin's "kabul edildi" tap IS the sale; there is no
                                     // approval step and no other status value.
  "createdAt": "<timestamp>",
  "updatedAt": "<timestamp>"
}
```
No `postId`/item reference or `deliveryAddress` — the negotiated item and delivery details live in the
chat conversation itself, not on the order record. (Dropped by explicit request; previously `postId` was
captured via a dropdown and `deliveryAddress` via a text field in the accept-order sheet — there is no
automatic way to infer which post was discussed from chat context, since a chat thread is scoped to a
user↔store pair, not a specific post. If Phase 4's Super Admin order dashboard ever needs to show the
item or delivery address, one of those fields will need to come back.)

## `stores/{storeId}/leaderboard/{userId}`
```jsonc
{
  "userId": "uid",
  "userName": "Karimowa Shirin",     // denormalized from users/{userId}.name at write time — avoids
                                      // N+1 reads for a top-20 list; refreshed on every order.
  "quantity": 7,                     // sum of orders.itemQuantity for this user at this store —
                                      // incremented by onOrderCreated, never written by the client.
  "updatedAt": "<timestamp>"
}
```
Denormalized aggregate, not a live query over `orders` — `orders` reads are restricted to Super Admin +
that store's admins (privacy), but the leaderboard tab is visible to any signed-in user. `onOrderCreated`
increments this doc (`FieldValue.increment`) in the same trigger that already notifies Super Admins,
right after every order (every order is created already-`accepted`, see above) — instant, no separate
"piggy bank" collection. Client reads `orderBy('quantity', desc).limit(20)` per store.

## `users/{uid}/notifications/{notificationId}`
```jsonc
{
  "title": "SeMay sent you a message",
  "body": "Yes we can deliver it. Where should we deliver to?",
  "createdAt": "<timestamp>",
  "read": false
}
```
Server-written only (`broadcastNotification`, `onMessageCreated`) — independent of FCM delivery, so the
in-app notifications screen and the bell icon's unread badge stay correct even if a device had no push
token (or was offline) when a push went out. The client may only flip `read` to `true`.

## `stores/{storeId}/quickReplies/{replyId}`
```jsonc
{
  "text": "Yes we can deliver it. Where should we deliver to?",
  "order": 0,                   // manual drag-to-reorder position, ascending
  "createdAt": "<timestamp>"
}
```
Discovered via Settings screen Figma frames (not in the original screen inventory in
`04_SCREENS_AND_NAVIGATION.md`) — Store Admin's canned chat responses, inserted into the message
composer. Store-scoped (any of that store's admins can manage/use them), write access same as other
store-owned data (that store's `adminIds`/claim check).

## `notificationRequests/{requestId}`
```jsonc
{
  "storeId": "storeId1",
  "storeName": "SeMay",             // denormalized at request time — used as the push title when
                                     // approved, since store admins only type a message body.
  "requestedBy": "uidOfAdmin",
  "message": "20% off this weekend only!",   // max 500 chars, validated server-side
  "status": "pending",              // "pending" | "approved" | "rejected"
  "createdAt": "<timestamp>",
  "decidedAt": "<timestamp> | null",
  "decidedBy": "superadminUid | null"
}
```
Store Admin → Super Admin broadcast-notification request flow: a store admin taps "+" on their
Settings → Notifications row (`requestBroadcastNotification` callable) to ask the Super Admin to
broadcast a message to all users; the Super Admin panel's Notification Requests page lists pending
requests and approves/rejects (`decideNotificationRequest` callable) — approval fans the message out
via the same `broadcastToAllUsers` helper used by the existing direct Super-Admin broadcast, and the
requesting admin sees the resulting status (approved/rejected) on their own request-history screen.
Admin-SDK-only writes (`allow write: if false` in rules) — status changes only happen via the
callables above, never direct client writes. Readable by the Super Admin and by that store's own
admins (their own requests only). Needs two composite indexes (`firestore.indexes.json`):
`status ASC, createdAt ASC` (web-admin's pending-queue page) and `storeId ASC, createdAt DESC`
(mobile's per-store request-history screen) — missing either one 500s that query.

## `otp_codes/{phone}`
```jsonc
{
  "code": "482913",
  "expiresAt": "<timestamp>",
  "lastSentAt": "<timestamp>",
  "attempts": 0,
  "lockedUntil": "<timestamp | absent>"
}
```
Admin-SDK-only (`allow read, write: if false` in `firestore.rules`) — never read or written by the
client directly, only via the `sendOtp`/`verifyOtp` Cloud Functions. `lastSentAt` drives the 60s resend
cooldown (`sendOtp` reuses the same `code` on resend rather than minting a new one, as long as the
previous one hasn't expired). `lockedUntil` is set once `attempts` hits 5 wrong tries — locks the phone
number for 1 hour, blocking both `sendOtp` and `verifyOtp` until it passes; by the time it does, the
code has always also expired (lockout > TTL), so the client needs a fresh `sendOtp` call regardless of
`attempts`.
Short-lived, cleaned up by a scheduled Cloud Function (e.g. daily deletion of expired docs).

## Denormalization notes
- `stores.postsCount` / `reelsCount` are incremented/decremented by Cloud Function triggers on
  `posts` create/delete — never trust a client-side count.
- `posts.likesCount` / `savesCount` same pattern — Cloud Function keeps them in sync with the `likes`
  subcollection and the `saved` collection.
- `posts.viewsCount` / `sentCount` / `sharesCount` all follow the same pattern: a unique-per-user
  subcollection (`views` / `sent` / `shares`) plus a create-only trigger (`onViewCreated` /
  `onSentCreated` / `onShareCreated`) that increments the corresponding count exactly once per
  unique user, regardless of how many times that user repeats the underlying action.
- Order analytics for Super Admin (item quantity totals by store/date — no status breakdown, every
  order counts) should be computed either via a
  scheduled aggregation Cloud Function into an `analytics/dailySummary/{date}` doc, or queried live if
  volume stays low. Firestore can't do SQL-style GROUP BY, so this needs to be decided once you know
  expected order volume.
