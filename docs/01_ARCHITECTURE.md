# Architecture

## 1. High-level

```
┌─────────────────────┐     ┌──────────────────────┐     ┌─────────────────────┐
│  Flutter Mobile App │     │   Firebase Backend    │     │  Next.js Web Panel  │
│  (User + Store      │◄───►│  Auth (custom claims) │◄───►│  (Super Admin only) │
│   Admin modes)       │     │  Firestore            │     │                     │
└─────────────────────┘     │  Storage              │     └─────────────────────┘
                             │  Cloud Functions       │
                             │  FCM                  │
                             └──────────────────────┘
```

One Flutter codebase serves **both** User and Store Admin — same login, UI branches by role claim.
Super Admin is web-only, separate Next.js app, no Flutter involvement.

## 2. Auth flow (custom OTP — NOT Firebase Phone Auth)

Reasoning: Firebase Phone Auth doesn't reliably support Turkmen (+993) numbers, and you're supplying
your own SMS sending mechanism. So we bypass Firebase's built-in phone verification and drive it
ourselves through Cloud Functions + Firestore + Firebase Custom Tokens:

1. **`sendOtp(phone)`** — Cloud Function (callable/HTTPS)
   - Generates a 6-digit code.
   - Writes to Firestore `otp_codes/{phone}`: `{ code, expiresAt (now+5min), attempts: 0 }`.
   - Calls a pluggable `SmsProvider` interface to actually send the SMS — **stub implementation
     provided**, you plug in your real gateway's API call here.
2. **`verifyOtp(phone, code)`** — Cloud Function
   - Validates code + expiry + attempt count (rate-limit: max 5 tries).
   - On success: finds or creates a `users/{uid}` doc keyed by phone.
   - Issues a **Firebase Custom Token** (`admin.auth().createCustomToken(uid, { role })`).
   - Client calls `signInWithCustomToken()` — from this point on, standard Firebase Auth session +
     security rules apply normally.
3. New users are asked for their name (per the "Login Name" Figma screen) right after first
   verification, before landing on the Homepage.

Custom claims used everywhere for authorization: `role: 'user' | 'admin' | 'superadmin'`, and for
admins, `storeIds: [storeId, ...]` (an admin can belong to multiple stores if you ever want that,
though your current spec is one-to-many stores→admins, not many-to-many — flag if that's wrong).

## 3. Firestore as source of truth
See `02_DATA_MODEL.md` for full schema. Security rules will:
- Let any authenticated user read posts/stores/stories.
- Let only a store's admins write posts/stories/reels/settings for *their* store(s).
- Let only Super Admin write to `stores` (create) and grant admin claims. `orders` are never
  client-written by anyone, including Super Admin — only the `acceptOrder` Cloud Function (Admin SDK)
  creates them, and they're never updated afterward.
- Restrict `chats/{chatId}/messages` to the two participants (user + that store's admins).

## 4. Storage layout (Firebase Storage)
```
/stores/{storeId}/avatar.jpg
/stores/{storeId}/cover.jpg
/stores/{storeId}/posts/{postId}/{index}.jpg|mp4
/stores/{storeId}/stories/{storyId}.jpg|mp4
/users/{uid}/avatar.jpg
```
Cloud Function trigger on upload can generate thumbnails for videos (reels) so the feed doesn't have to
load full video files just to show a preview frame.

## 5. Real-time chat
Firestore listeners (no separate socket server needed) — `chats/{chatId}/messages` subcollection with
`onSnapshot` in Flutter. Good enough at this scale; revisit only if message volume becomes very high.

## 6. Push notifications (FCM)
Cloud Function triggers on:
- New message in a chat → notify the other participant(s).
- New order (`orders` doc created) → notify Super Admin.
- (Assumed default, see Open Items) likes/comments on your own post → notify the store admin.

## 7. Flutter app structure (proposed)
```
lib/
  main.dart
  core/
    router.dart              # go_router, role-based redirects
    theme.dart                # colors/typography from Figma tokens
    firebase_options.dart
  features/
    auth/                     # phone entry, OTP, name entry
    feed/                     # Homepage (discovery feed), stories bar
    story_viewer/
    store_profile/            # Store Detail screen (shared: user view + admin's own-store view)
    post_composer/            # admin: create post/carousel/reel
    story_composer/           # admin: create story
    reels/                    # admin: Reels tab, MyReel
    chat/                     # conversation list + thread, "kabul edildi" button
    profile/                  # user profile, liked, saved, notifications
    admin_settings/           # store admin settings
  shared/
    widgets/
    models/                   # Post, Store, User, Order, Message, Story
    services/
      auth_service.dart
      firestore_service.dart
      storage_service.dart
      notification_service.dart
  state/                       # Riverpod or Bloc — pick one (assumption: Riverpod, flag if you prefer Bloc)
```

## 8. Web Super Admin (Next.js, proposed)
```
/app
  /login                     # email+password or Google, Super-Admin-only (separate from phone OTP)
  /dashboard                 # read-only order report: item quantity totals by day/store
  /stores                    # list, create
  /stores/[id]/admins        # promote/demote admins for that store
```
Super Admin login mechanism is a **separate concern from the phone-OTP flow** — proposal: plain
email/password via Firebase Auth for the (small, trusted) Super Admin user set. Flag if you want phone
OTP here too.

## 9. Why Firebase over a custom backend
You picked Firebase explicitly — noting here for the record: it gets you Auth/Storage/Firestore/FCM/
Hosting without standing up servers, at the cost of vendor lock-in and Firestore's query limitations
(no full joins/aggregations — analytics on `orders` will need either denormalized counters or scheduled
Cloud Functions that compute aggregates, not live SQL-style GROUP BY).
