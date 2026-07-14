# Build Roadmap

## Phase 0 — Foundations (this session's next step)
- Firebase project setup (Auth, Firestore, Storage, Functions, FCM, Hosting).
- Flutter project scaffold: routing, theme tokens pulled from Figma (colors, typography), folder
  structure from `01_ARCHITECTURE.md`.
- Cloud Functions scaffold: `sendOtp`/`verifyOtp` (with stub `SmsProvider`), custom claims setup.
- Firestore security rules v1 + emulator setup for local dev.

## Phase 1 — Auth + core navigation
- Phone → OTP → Name flow, end-to-end against Firebase emulator.
- Role-based routing (user vs admin shell).
- Bottom nav / top structure matching Homepage, Store Detail, Chat, Profile tabs.

## Phase 2 — Content: feed, posts, stories
- Post model + Firestore reads for Homepage discovery feed (pagination).
- Store Detail screen (grid + reels tabs, bio, message/call buttons).
- Post composer for admins (image, carousel, reel upload to Storage).
- Story composer + full-screen story viewer with progress bar.
- Like / comment / save interactions + denormalized counters via Cloud Functions.

## Phase 3 — Chat + orders
- Real-time chat thread (Firestore listeners), conversation list.
- "kabul edildi" button → `acceptOrder` function → order created → system message in chat.
- Push notifications for new messages and new orders.

## Phase 4 — Super Admin web panel
- Next.js scaffold, Super Admin auth.
- Store creation UI.
- Admin promote/revoke UI.
- Orders dashboard with filters + basic analytics (totals by status/store/date).

## Phase 5 — Polish & open items resolution
- Resolve all "Open Items" from `00_PROJECT_OVERVIEW.md` (story expiry, video size caps, comment
  moderation, order status workflow, store categories, localization, notification scope).
- App icons, splash screens, store listing assets.
- Testing pass (auth edge cases, offline behavior, large video uploads).

---
**Recommendation for right now:** confirm or correct the assumptions flagged throughout these five docs
(search for "assumption", "flag if", and "Open Items" across the files), then I'll scaffold Phase 0 —
the actual Firebase + Flutter project structure and starter code.
