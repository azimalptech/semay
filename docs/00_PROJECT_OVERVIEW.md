# SeMay — Project Overview & PRD

## 1. What this is
An Instagram-style mobile app (Android + iOS, **Flutter**) where independent **stores** post content
(photos, carousels, reels, stories), and **users** browse, like, comment, save, and place orders via
direct chat with the store. A **web Super Admin panel** manages stores, admins, and order analytics.

Backend: **Firebase** (Auth via custom OTP flow, Firestore, Storage, Cloud Functions, FCM, Hosting for
the Super Admin web panel).

## 2. Roles

| Role | Access | Created by |
|---|---|---|
| **User** | Mobile app only | Self sign-up (phone number) |
| **Store Admin** | Mobile app (admin mode) | Promoted by Super Admin from an existing user account |
| **Super Admin** | Web panel only | Seeded manually (no self sign-up) |

A single **store** can have **multiple admins** (confirmed). An admin account is just a user account
with an `admin` role claim scoped to one or more `storeId`s — the same phone/OTP login is used, and the
app UI switches into "Store Admin mode" for that person.

## 3. Role capabilities

### Super Admin (web)
- Create stores (name, tagline, avatar, cover, phone, address).
- Promote/demote a user to Store Admin for a given store (grant/revoke admin privileges on existing
  accounts — Super Admin never creates admin accounts from scratch, only elevates existing users).
- View all **orders** across all stores — **read-only** daily reporting (total item quantity ordered
  per day, per store). No approval step, no status, no per-order editing — the Store Admin's "kabul
  edildi" tap already is the completed sale; Super Admin only ever views aggregated numbers.
- No content moderation scope defined yet (posts publish directly, no approval step — see Open Items).

### Store Admin (mobile, admin mode)
- Create posts: single image, carousel (multi-image), or **reel** (video, no duration limit).
- Create stories (photo/video, no duration limit on the video itself).
- Edit/delete their store's own posts.
- Chat with users; reply to messages.
- Tap **"kabul edildi"** (order accepted) above the chat once an order is verbally/textually agreed —
  this sends `{ itemQuantity, userPhone }` to Super Admin as a new **Order** record for analytics.
  `userPhone` is auto-filled from the customer's profile, not typed. The item being discussed and the
  delivery address stay negotiated in the chat itself and are not captured on the order record
  (changed from the original spec by explicit request — flag if the Super Admin dashboard needs them
  after all).
- Manage their own store profile / settings.

### User (mobile)
- Browse a **global discovery feed** (no follow system — Homepage shows posts from all stores,
  Instagram-Explore-style, confirmed).
- View a store's profile (Store Detail: grid of posts + reels tab, bio, phone, location, message/call).
- Like, comment, save (favorite) posts.
- View stories.
- Chat with a store's admin(s) to negotiate/place an order.
- Manage own profile, saved posts, liked posts, notifications.

## 4. Post structure (1:1 with Instagram)
- Media: single image, multi-image carousel, or video (reel).
- Caption/description text.
- Like count, comment count, save count.
- Comments are threaded flat (no nested replies unless you want that — **assumption**, flag if wrong).
- Stories: photo/video, story-ring UI on avatars, **assumed 24h expiry** like Instagram (not stated in
  your spec — this is a default we're flagging, not something we invented silently; confirm or override).

## 5. Order flow (confirmed)
1. User chats with Store Admin, negotiates item + quantity informally in chat.
2. Store Admin taps **"kabul edildi"**.
3. App captures: item quantity and user's phone number (auto-filled from their profile, not typed),
   plus store/admin identifiers automatically. The specific item/post and delivery address stay
   negotiated in the chat conversation and are not stored on the order record.
4. This is sent to Super Admin as an **Order** record with status `accepted` — always `accepted`, set
   once at creation. The "kabul edildi" tap *is* the sale; there is no approval step.
5. Super Admin never edits, approves, or transitions an order — it's a read-only reporting record from
   here on. The Super Admin panel aggregates these into a daily (and per-store) item-quantity report.

## 6. Confirmed technical decisions
- **Mobile:** Flutter (single codebase, Android + iOS).
- **Backend:** Firebase (Auth, Firestore, Storage, Cloud Functions, FCM).
- **Phone OTP:** Custom-built OTP sender (NOT Firebase Phone Auth) — see `03_CLOUD_FUNCTIONS_API.md`
  for the pluggable-SMS-provider design. You will supply the actual SMS gateway integration later.
- **Web Super Admin panel:** Next.js + Firebase (assumption — standard fit for a Firebase backend;
  flag if you want something else).
- **Admins per store:** multiple allowed.
- **Feed model:** global discovery feed, no follow system.

## 7. Open items — need your input before/while building
These are not blocking the initial scaffold, but need answers before we finalize the corresponding
features:

1. **Story expiry** — 24h like Instagram, or permanent until manually deleted?
2. **Video size cap** — "no duration limit" is confirmed, but do we cap file size (e.g. 500MB) to
   control Firebase Storage/bandwidth cost, or truly unlimited?
3. **Comment moderation** — can Store Admins delete/hide comments on their own posts?
4. **Store categories** — is every store the same "type" (like the SeMay beauty example in the design),
   or do stores have a category/niche field used for filtering?
5. **Localization** — single language for launch, or multi-language (a "Profile Language" screen exists
   elsewhere in the Figma file, just outside the sections you scoped to me)?
6. **Push notifications** — assumed default: new message, order-related updates, likes/comments on your
   own post. Confirm scope or trim it.

(Order status workflow — previously open item #4 — is resolved: there is no workflow, `status` is
always `'accepted'`, Super Admin is read-only. See §5.)

## 8. Explicitly out of scope (per your instructions)
- No cart/checkout/product-catalog browsing (those screens exist in the Figma file but outside the
  User/Store Admin sections you pointed me to — a different, older project living in the same file).
- No in-app payments — orders are negotiated in chat, not paid for in-app.
