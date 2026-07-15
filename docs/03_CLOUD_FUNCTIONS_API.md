# Cloud Functions (Backend API surface)

All callable from Flutter via `cloud_functions` SDK unless noted as a background trigger.

## Auth
### `sendOtp({ phone })`
- Rate-limited (e.g. 1 request / 60s per phone, enforced via the `otp_codes` doc's `expiresAt`/last-sent
  timestamp).
- Generates 6-digit code, writes `otp_codes/{phone}`, calls `SmsProvider.send(phone, code)`.
- `SmsProvider` is an interface (`sendSms(phone, message): Promise<void>`) with a stub/logging
  implementation checked in — **you will implement the real gateway call**.

### `verifyOtp({ phone, code })`
- Checks `otp_codes/{phone}`: not expired, `attempts < 5`, code matches.
- On mismatch: increments `attempts`, throws.
- On match: deletes/marks the OTP doc verified, finds or creates `users/{uid}` by phone, returns a
  Firebase custom token.
- If the user doc is new, response includes `isNewUser: true` so the client routes to the "Login Name"
  screen before Homepage.

### `completeProfile({ name })`
- Sets `users/{uid}.name`, only callable by the authenticated user for their own doc.

## Super Admin only (enforced via `role == 'superadmin'` custom claim check)
### `createStore({ name, tagline, phone, address, avatarUrl, coverUrl })`
- Creates `stores/{storeId}`, `createdBy = superadminUid`.

### `setStoreAdmin({ storeId, userId, grant: true|false })`
- Grants: adds `userId` to `stores/{storeId}.adminIds`, sets that user's custom claim `role='admin'`
  and adds `storeId` to their `storeIds`.
- Revokes: inverse. If a user ends up with zero `storeIds` after revoke, role reverts to `'user'`.

Super Admin has no order-mutating function — orders are read-only for Super Admin (reporting only, no
approval step, no status transitions). There is no `updateOrderStatus`.

## Store Admin only (enforced via `role == 'admin'` + `storeIds` contains the target store)
### `acceptOrder({ chatId, itemQuantity, userPhone })`
- Creates `orders/{orderId}` with `status: 'accepted'` — this is the only status value that ever
  exists; the tap itself is the completed sale, not a pending request. `userPhone` is auto-filled
  client-side from `users/{userId}.phone` (not manually typed) — no post/item reference or delivery
  address is captured; those stay negotiated in the chat conversation, not on the order record.
- Writes a system message into `chats/{chatId}/messages` referencing the new `orderId` (so the chat
  thread shows "Order accepted ✅" inline).
- Triggers a notification to Super Admin (see below).

## Background triggers (no client call — fire automatically)
- **`onOrderCreated`** (Firestore trigger on `orders` create) → sends FCM push to all Super Admin
  accounts.
- **`onMessageCreated`** (trigger on `chats/{chatId}/messages` create) → FCM push to the other
  participant (user or that store's admins).
- **`onPostCreated` / `onPostDeleted`** (trigger on `posts`) → increments/decrements
  `stores/{storeId}.postsCount` or `reelsCount` depending on `type`.
- **`onLikeWrite` / `onCommentCreated` / `onSavedWrite`** → keep `posts.likesCount` /
  `commentsCount` / `savesCount` in sync.
- **`cleanupExpiredOtps`** (scheduled, daily) → deletes stale `otp_codes` docs.
- **`expireStories`** (scheduled, hourly) — only if you confirm 24h expiry — deletes/hides stories past
  `expiresAt`.

## Security rules summary (Firestore)
- `stores`, `posts`, `stories`: public read (any authenticated user), write restricted to that store's
  admins (checked via custom claim `storeIds` array-contains match, not just `adminIds` on the doc —
  claims are the source of truth for security rules since rules can't easily do array-contains against
  another doc without an extra `get()`).
- `orders`: create only via the `acceptOrder` Cloud Function (not direct client writes) and never
  updated afterward (`status` is fixed at `'accepted'`); read restricted to Super Admin and the store's
  admins (their own store's orders only).
- `chats/{chatId}/messages`: read/write restricted to `chatId`'s `userId` and that store's admins.
- `users/{uid}`: self read/write only, except Super Admin can read all (for the admin-assignment UI).
