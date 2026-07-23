# 06 — Deploying the backend

Everything in `backend/` (Cloud Functions, Firestore rules + indexes, Storage rules) and
`web-admin/` (Super Admin panel) ships through **Firebase**, driven by `backend/firebase.json`.
`web-admin`'s hosting entry (`"hosting": { "source": "../web-admin" }`) uses Firebase Hosting's
built-in Next.js framework support — `firebase deploy --only hosting` builds and deploys it to
Cloud Run automatically (that's why its live URL is a `*.run.app` address), no separate
Docker/Cloud Run commands needed.

The mobile app (`mobile/`) is **not** part of this deploy — it ships as a built APK
(`flutter build apk --release`), installed directly to a device, not deployed to a server.

All commands below are run from `backend/` (where `firebase.json` and `.firebaserc` live), using
`npx firebase` since firebase-tools isn't installed globally in this project.

## One-time setup (already done in this environment, listed for a fresh machine)

```bash
cd backend
npx firebase login
npx firebase projects:list        # confirms access to semay-b57ee
npx firebase use semay-b57ee      # or just rely on .firebaserc's "default"
```

## Pre-deploy checks

Run these first — `firebase deploy`'s `functions` target already runs `npm run build` as a
`predeploy` hook (see `firebase.json`), but catching errors here is faster than waiting on the
deploy to fail partway through.

```bash
# Cloud Functions — TypeScript typecheck
cd backend/functions
npx tsc --noEmit

# web-admin — TypeScript typecheck
cd web-admin
npx tsc --noEmit
```

## Deploy everything

```bash
cd backend
npx firebase deploy
```

This deploys, in one shot: Cloud Functions, Firestore rules, Firestore indexes, Storage rules,
and the web-admin panel (hosting). Safe to re-run — Firebase only ships what actually changed
per target.

## Deploy one target at a time

Useful when you only touched one part and want a faster, narrower deploy.

```bash
cd backend

# Cloud Functions only (all functions in src/index.ts)
npx firebase deploy --only functions

# A single function (faster iteration — replace with the function name)
npx firebase deploy --only functions:deleteStore

# Firestore security rules only
npx firebase deploy --only firestore:rules

# Firestore composite indexes only (new indexes take a few minutes to finish
# building server-side after this returns — queries needing them will 500 with
# FAILED_PRECONDITION until the build completes)
npx firebase deploy --only firestore:indexes

# Storage security rules only
npx firebase deploy --only storage

# web-admin (Super Admin panel) only
npx firebase deploy --only hosting
```

## Post-deploy verification

```bash
# Tail live Cloud Functions logs (add --only <name> to scope to one function)
npx firebase functions:log

# Confirm the hosting deploy's live URL
npx firebase hosting:sites:list
```

Then smoke-test in the actual app/panel — deploying doesn't verify behavior, it just ships code.

## Super Admin web panel — which URL to actually use

**Log in at the direct Cloud Run URL, NOT `https://semay-b57ee.web.app`.** The panel's session
cookie is named `session`, deliberately not `__session` (that exact name is reserved by Firebase
Hosting's own Next.js SSR auto-auth, which mis-handles it and crashed SSR — see the long comment
in `web-admin/src/app/api/session/route.ts`). But Firebase Hosting's CDN only forwards a cookie
named exactly `__session` to the backend, so through `*.web.app` the login cookie is silently
dropped and you bounce back to `/login` even with the right password. Reach the panel at its
Cloud Run URL instead:

```bash
# Find the current SSR service URL (the ssrsemayb57ee run.app address)
npx firebase hosting:sites:list
# …or read it off the `firebase deploy --only hosting` output ("Function URL (…ssrsemayb57ee…)").
```

Login is **email + password** (Firebase Auth), gated to `role == 'superadmin'` — this is separate
from the mobile app's phone/OTP auth. There is no self-service way to mint the first superadmin;
it's bootstrapped manually (create the Auth user + set the `role: 'superadmin'` custom claim via
the Admin SDK / Firebase console).

## Cloud Run CPU quota — the real scaling gate

Deploying all ~24 functions at once repeatedly hit **"Quota exceeded for total allowable CPU per
project per region"** (a Cloud Run quota, not a code error) — individual functions failed to roll
out while their old revisions kept serving. Two mitigations are in place:

- `backend/functions/src/index.ts` calls `setGlobalOptions({ cpu: 0.5, concurrency: 1 })`, roughly
  halving the CPU a deploy needs. Latency-sensitive functions override back to full: `deleteStore`
  (`cpu: 1`), and `sendOtp` / `verifyOtp` / `onMessageCreated` (`cpu: 1, concurrency: 80`).
- If a deploy still fails on the quota, re-run `firebase deploy --only functions:<name>` for just
  the failed ones once the concurrent rollout has settled; the old revision keeps serving in the
  meantime, so nothing goes down.

**Before any real-scale launch, request a Cloud Run CPU quota increase** in the GCP Console
(IAM & Admin → Quotas → filter "Cloud Run Admin API" / CPU allocation, region `us-central1`). Once
raised, the global `cpu: 0.5 / concurrency: 1` cap can be dropped entirely.

## Current deployed state (as of this session)

Everything below has been **deployed** to `semay-b57ee` (functions + firestore rules/indexes +
storage + hosting). This section is the inventory, not a pending list.

- **Cloud Functions** (all in `src/index.ts`): auth (`sendOtp`, `verifyOtp`, `changePhone`,
  `completeProfile`, `dispatchQueuedSms`); posts (`onPostCreated`, `onPostDeleted`, `onLikeWrite`,
  `onSavedWrite`, `onViewCreated`, `onSentCreated`, `onShareCreated`); stories (`expireStories`);
  chat (`onMessageCreated`); orders (`acceptOrder`, `onOrderCreated`); stores (`createStore`,
  `setStoreAdmin`, `deleteStore`); admin (`broadcastNotification`, `requestBroadcastNotification`,
  `decideNotificationRequest`, `setLeaderboardCampaignStart`).
- **`firestore.rules`** — hardened users/stores/posts/chats/messages rules; `stores` delete forced
  through `deleteStore` (`allow delete: if false`); `posts` views/sent/shares + `notificationRequests`
  match blocks; chat-doc update allowlist includes the per-side `hiddenByUserAt`/`hiddenByAdminAt`
  soft-delete stamps.
- **`firestore.indexes.json`** — composite indexes for `orders` (both createdAt directions),
  `notificationRequests` (`status,createdAt` and `storeId,createdAt`), and `chats`
  (`storeId,lastMessageAt` for the inbox window + `storeId,unreadByAdmin` for the unread badge).
- **web-admin hosting** — the Super Admin panel (Next.js on Cloud Run), including the Notification
  Requests approve/reject page. Live at the `ssrsemayb57ee-…run.app` URL (see the caveat above).

Nothing in the working tree is pending deploy; the only outstanding action is that **none of this
session's source changes are committed to git yet** — `git status` in the repo root shows the full
set. Commit before treating the tree as a stable baseline.
