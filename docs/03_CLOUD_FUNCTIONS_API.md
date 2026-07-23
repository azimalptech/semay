# Cloud Functions (Backend API surface)

All callable from Flutter via `cloud_functions` SDK unless noted as a background trigger.

## Auth
### `sendOtp({ phone })`
- Rate-limited to 1 request / 60s per phone (`otp_codes.lastSentAt`), plus a shared
  `otp_send_rate_limit` minute-bucket cap (20/min) across all phones.
- If a live (unexpired) code already exists for this phone, resends that *same* code rather than
  minting a new one; otherwise generates a fresh 6-digit code. Writes `otp_codes/{phone}`.
- Does **not** call the SMS gateway directly. `SmsProvider` (`backend/functions/src/sms/
  smsProvider.ts`) is the interface (`sendSms(phone, message, simIndex?): Promise<void>`); the real
  implementation, `SmsGatewayProvider`, talks to a physical Android phone running the
  capcom6/android-sms-gateway app (Cloud Server mode) — carriers throttle/flag a SIM that fires SMS
  in a tight burst, so actual sends are paced through a queue instead of firing immediately:
  `sendOtp` reserves a slot via `reserveDispatchSlot()` (`sms/smsDispatchQueue.ts`, a Firestore-
  transaction-based cursor — one global slot every 6s, `SEND_INTERVAL_MS`), writes it to
  `sms_dispatch_queue/{id}`, and the `dispatchQueuedSms` background trigger (fires on that
  collection's create) sleeps until the slot and only then calls the gateway. This means `sendOtp`
  returning success means "queued for delivery," not "delivered" — the client doesn't need to know
  the difference since the OTP screen already tolerates arbitrary delivery delay via the 5-minute
  code TTL. A request whose slot would land after the code's TTL (deep backlog, `MAX_QUEUE_DELAY_MS`
  in smsDispatchQueue.ts) is rejected with `resource-exhausted` instead of silently queuing an SMS
  that will arrive already-expired.
- Response includes `devCode` (the plaintext code) only when running under the Functions emulator,
  `null` otherwise — lets the app show a dev-only banner during testing without a real SMS gateway
  (the emulator's `LoggingSmsProvider` just logs instead of sending).
- Throws `resource-exhausted` (with `lockedUntil` in `details`) if the phone is currently locked out —
  see `verifyOtp` below.

### `dispatchQueuedSms` (Firestore trigger on `sms_dispatch_queue` create)
- Sleeps until its item's `scheduledAt`, re-verifies the code hasn't expired in the meantime (marks
  `status: "skipped_expired"` and returns if so), then calls `SmsProvider.sendSms`. Not callable from
  the client — internal to the OTP send-pacing pipeline described above.

### `verifyOtp({ phone, code })`
- Checks `otp_codes/{phone}`: not locked out, not expired, code matches.
- On mismatch: increments `attempts` and throws `invalid-argument` with `attemptsRemaining` in
  `details`. On the 5th wrong attempt, additionally sets `lockedUntil` (now + 1h) and throws
  `resource-exhausted` with `lockedUntil` in `details` instead — blocks both `sendOtp` and `verifyOtp`
  for that phone until it passes.
- On match: deletes the OTP doc, finds or creates `users/{uid}` by phone, returns a Firebase custom
  token.
- **One phone = one account, guaranteed** — a new account's uid is derived deterministically from the
  phone (`u_` + sha256(phone) prefix), so two devices verifying the same brand-new number
  simultaneously converge on the same uid instead of each creating an account: one `createUser` wins,
  the other catches `auth/uid-already-exists` and reuses it. Accounts created before this scheme keep
  their random uids and are still matched by the `where phone == …` lookup (which handles every
  non-simultaneous login). This replaced a check-then-create race that could mint duplicate accounts
  for a single number.
- If the user doc is new (or exists but has an empty `name`), response includes `isNewUser: true` so
  the client routes to the "Login Name" screen before Homepage.

### `completeProfile({ name })`
- Sets `users/{uid}.name`, only callable by the authenticated user for their own doc.

## Super Admin only (enforced via `role == 'superadmin'` custom claim check)
### `createStore({ name, tagline, phone, address, avatarUrl, coverUrl })`
- Creates `stores/{storeId}`, `createdBy = superadminUid`.

### `setStoreAdmin({ storeId, userId, grant: true|false })`
- Grants: adds `userId` to `stores/{storeId}.adminIds`, sets that user's custom claim `role='admin'`
  and adds `storeId` to their `storeIds`.
- Revokes: inverse. If a user ends up with zero `storeIds` after revoke, role reverts to `'user'`.

### `deleteStore({ storeId })`
- Irreversible cascade delete. Removes `stores/{storeId}` and everything a bare doc delete would
  orphan: that store's `posts` (each deletion fires the existing `onPostDeleted` trigger, which
  recursively removes that post's `likes` subcollection and Storage media), `stories` (+ their `views`
  subcollections), `chats` (+ their `messages` subcollections and Storage media), `orders`, and the
  store's own `quickReplies`/`leaderboard` subcollections, plus every Storage object under
  `stores/{storeId}/**`.
- Every admin who managed only this store is demoted back to `role='user'` with `storeIds` cleared of
  it (same transition `setStoreAdmin`'s revoke uses); an admin managing other stores keeps them.
- Does **not** clean up the denormalized `users/{uid}/liked/{postId}`/`users/{uid}/saved/{postId}`
  copies for that store's posts — same pre-existing gap a regular post delete already leaves; every
  screen that reads a post by id already treats a missing doc as a normal empty state.

Super Admin has no order-mutating function — orders are read-only for Super Admin (reporting only, no
approval step, no status transitions). There is no `updateOrderStatus`.

### `broadcastNotification({ title, body })`
- Fans a push + `users/{uid}/notifications` doc out to every user's registered `fcmTokens`, via the
  shared `broadcastToAllUsers(title, body)` helper (`utils/notify.ts`). `title` ≤100 chars, `body`
  ≤500 chars, both required.

### `decideNotificationRequest({ requestId, approve })`
- Approves/rejects a store admin's `notificationRequests/{requestId}` (see `requestBroadcastNotification`
  below and `02_DATA_MODEL.md`). Throws `failed-precondition` if the request isn't still `pending`.
- On reject: just stamps `status: 'rejected'`, `decidedAt`, `decidedBy` — nothing is sent.
- On approve: stamps the same fields `'approved'`, then calls `broadcastToAllUsers(storeName, message)`
  using the request's own denormalized `storeName` as the push title (store admins only type a message
  body, not a separate title) — same fan-out `broadcastNotification` uses directly. Returns
  `{ sent, failed }`.

## Store Admin only (enforced via `role == 'admin'` + `storeIds` contains the target store)
### `acceptOrder({ chatId, itemQuantity, userPhone })`
- Creates `orders/{orderId}` with `status: 'accepted'` — this is the only status value that ever
  exists; the tap itself is the completed sale, not a pending request. `userPhone` is auto-filled
  client-side from `users/{userId}.phone` (not manually typed) — no post/item reference or delivery
  address is captured; those stay negotiated in the chat conversation, not on the order record.
- Writes a system message into `chats/{chatId}/messages` referencing the new `orderId` (so the chat
  thread shows "Order accepted ✅" inline).
- Triggers a notification to Super Admin (see below).

### `requestBroadcastNotification({ storeId, message })`
- Creates a pending `notificationRequests/{requestId}` doc asking the Super Admin to broadcast
  `message` to all users (see `02_DATA_MODEL.md`) — only ever creates the request, nothing is sent
  until a Super Admin calls `decideNotificationRequest` above. `message` ≤500 chars, required. Caller
  must be an admin of `storeId` (checked against their `storeIds` custom claim, same as `isStoreAdmin`
  in `firestore.rules`).

## Client-written (no Cloud Function — direct Firestore write, rules-gated)
### "Send to chat" (share a post into an existing conversation)
- Not a callable — the client writes directly into `chats/{chatId}/messages` with `sharedPostId` set
  (see `02_DATA_MODEL.md`), same as any other message. No dedicated function; `onMessageCreated`
  (below) fires for it like any message.

### Gallery attachments in chat
- Not a callable — the client uploads the picked photo/video straight to Storage
  (`/chats/{chatId}/{file}`, gated by `storage.rules`) and then writes the message doc directly with
  `mediaUrl`/`mediaType` set, same pattern as "send to chat" above.

### Post view/sent/share counters
- Not callables. `PostsService.recordView(postId)` writes `posts/{postId}/views/{uid}` directly
  (`onViewCreated` below increments `viewsCount`); `recordSent(postId)`/`recordShare(postId)` write
  `posts/{postId}/sent/{uid}`/`shares/{uid}` the same way (`onSentCreated`/`onShareCreated` below
  increment `sentCount`/`sharesCount`). `recordSent` is only called after a chat send actually
  succeeds (`send_to_chat_sheet.dart`); `recordShare` (via `shareAndRecord`) only after the OS share
  sheet reports `ShareResultStatus.success` — never from the icon's `onTap` itself, and never more
  than once per user regardless of repeat sends/shares. See `02_DATA_MODEL.md` for details.

## Background triggers (no client call — fire automatically)
- **`onOrderCreated`** (Firestore trigger on `orders` create) → sends FCM push to all Super Admin
  accounts.
- **`onMessageCreated`** (trigger on `chats/{chatId}/messages` create) → updates the chat doc
  (`lastMessageText`/`lastMessageAt`, and increments the recipient's unread counter — skipped for the
  single-recipient "to the customer" case if their `users/{uid}.activeChatId` is already this chat).
  Then FCM push to the other participant (user or that store's admins), carrying `{chatId, messageId}`
  as the data payload (used client-side to mark that message `deliveredAt`, see `notification_service.
  dart`) — suppressed entirely if the chat is muted on the recipient's side (`mutedByUser`/
  `mutedByAdmin`), and per-recipient-token if that specific recipient's `activeChatId` is this chat
  (they're already looking at it).
- **`onPostCreated` / `onPostDeleted`** (trigger on `posts`) → increments/decrements
  `stores/{storeId}.postsCount` or `reelsCount` depending on `type`.
- **`onLikeWrite` / `onSavedWrite`** → keep `posts.likesCount` / `savesCount` in sync.
- **`onViewCreated`** (trigger on `posts/{postId}/views/{uid}` create) → increments
  `posts/{postId}.viewsCount`. Create-only (`onDocumentCreated`, not `onDocumentWritten`) since a
  view doc is never updated or deleted once written.
- **`onSentCreated`** / **`onShareCreated`** (triggers on `posts/{postId}/sent/{uid}` /
  `posts/{postId}/shares/{uid}` create) → increment `sentCount`/`sharesCount`. Same create-only
  reasoning as `onViewCreated`.
- **`cleanupExpiredOtps`** (scheduled, daily) → deletes stale `otp_codes` docs.
- **`expireStories`** (scheduled, hourly) — only if you confirm 24h expiry — deletes/hides stories past
  `expiresAt`.

## Security rules summary (Firestore)
- `stores`, `posts`, `stories`: public read (any authenticated user), write restricted to that store's
  admins (checked via custom claim `storeIds` array-contains match, not just `adminIds` on the doc —
  claims are the source of truth for security rules since rules can't easily do array-contains against
  another doc without an extra `get()`). `stores` deletion is `if false` — only the `deleteStore`
  callable (Admin SDK) may remove a store, so its cascade cleanup can't be bypassed by a bare doc
  delete.
- `posts/{postId}/views/{uid}`, `/sent/{uid}`, `/shares/{uid}`: write restricted to that user
  themself (their own uid), same pattern as `stories/{storyId}/views/{uid}`; read restricted to that
  post's own store admins. `posts.viewsCount`/`sentCount`/`sharesCount` themselves are never directly
  client-writable — only the corresponding trigger (Admin SDK) touches them.
- `notificationRequests`: `allow write: if false` — only `requestBroadcastNotification`/
  `decideNotificationRequest` (Admin SDK) may create or update these; read restricted to the Super
  Admin and that store's own admins.
- `orders`: create only via the `acceptOrder` Cloud Function (not direct client writes) and never
  updated afterward (`status` is fixed at `'accepted'`); read restricted to Super Admin and the store's
  admins (their own store's orders only).
- `chats/{chatId}/messages`: read/write restricted to `chatId`'s `userId` and that store's admins.
- `users/{uid}`: self read/write only, except Super Admin can read all (for the admin-assignment UI).
