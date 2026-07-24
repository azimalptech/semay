# 07 — Firebase → Self-Hosted MySQL Migration

**Status: IN PROGRESS (Phase 1).** Full architecture + rationale: the approved plan at
`.claude/plans/iterative-launching-meteor.md`. This doc is the living, in-repo reference kept
alongside the code as each phase lands.

## Why

Data sovereignty: all user data (Turkmen phone numbers, chats, orders) must live on infrastructure
the owner fully controls, **physically hosted in Turkmenistan**. Full migration off Firebase
(Firestore, Auth, Storage, Cloud Functions) — keeping **only FCM** for push. All current Firebase
data is disposable test data, so there is **no production data migration**: the new backend starts
empty and cutover is "point the app at the new server."

## New components

- **`server/`** — the new self-hosted API (Node.js + TypeScript, Fastify + `ws`, Prisma → MySQL 8,
  MinIO for media, Firebase Admin SDK for FCM send only). Replaces `backend/functions/` (Firebase
  Cloud Functions) and Firestore/Auth/Storage.
- **`backend/`** — the OLD Firebase Cloud Functions. Stays until cutover, then retired.
- **`mobile/`** / **`web-admin/`** — rewritten in Phases 9 / 8 to consume the new API; provider
  names/signatures kept stable so screens change minimally.

## Phase status

| Phase | What | Status |
|------|------|--------|
| 0 | **Owner:** provision TM server (MySQL 8, TLS, Node, MinIO, backups) | ⬜ owner task |
| 1 | Server scaffold + Prisma schema (`server/prisma/schema.prisma`) | 🟨 in progress |
| 2 | Auth (OTP, sessions, JWT fast/slow, phone-UNIQUE race) + concurrency test | ⬜ |
| 3 | Core CRUD + storage + authz middleware + per-route/role test matrix | ⬜ |
| 4 | Real-time WebSocket gateway (channel pub-sub, snapshot-then-diff) | ⬜ |
| 5 | Chat (list-diff channels, messages, receipts/typing/mute/hide) | ⬜ |
| 6 | Orders, leaderboard, notifications, quick replies, requests, broadcast | ⬜ |
| 7 | Relocate FCM sender; repoint token registration + delivery receipts | ⬜ |
| 8 | Web-admin rewrite (2-tier session, Prisma Server Components) | ⬜ |
| 9 | Mobile rewrite (REST/WS/outbox client) + 9b offline SQLite outbox | ⬜ |
| 10 | Staging rehearsal, two-device test, cutover | ⬜ |

## Schema: notable relational changes from Firestore

Field-for-field the schema mirrors `docs/02_DATA_MODEL.md`; these are the deliberate structural
differences (all documented inline in `server/prisma/schema.prisma`):

- **`store_admins` junction table** replaces BOTH `stores.adminIds` and `users.storeIds` arrays —
  the old hand-maintained dual-write drift bug is designed out. `role` stays a column on `users`.
- **`users.id` is a random UUID again** (not sha256(phone)). The `phone UNIQUE` constraint IS the
  "1 phone = 1 account" lock now — a plain INSERT that hits duplicate-key (MySQL 1062) makes the
  loser re-SELECT the winner's row. This is the SQL-native fix for the race the deterministic-uid
  trick worked around under Firestore.
- **`post_media`** replaces `posts.mediaUrls[]` (real `position` ordering column + deletable rows).
- **`post_likes/saves/views/sent/shares`** each replace an existence-checked subcollection. The old
  `users/{uid}/liked` and `users/{uid}/saved` mirror collections are **dropped** — `INDEX(userId,
  createdAt)` on `post_likes`/`post_saves` serves "My Liked/Saved" directly.
- **`chats.id` keeps the deterministic `${userId}_${storeId}` PK** — `createOrGetChat` becomes an
  `INSERT IGNORE` in a synchronous transaction, so the Firestore `!hasPendingWrites` race workaround
  is structurally impossible (no client write-cache in MySQL).
- **`messages.id` is an AUTO_INCREMENT BIGINT** — monotonic ordering replaces `orderBy(createdAt)
  .limitToLast(200)`.
- **`user_fcm_tokens.token` is UNIQUE** — upsert-on-conflict fixes the reinstall/relogin token
  ownership ambiguity `arrayUnion` had.
- **`price DECIMAL(10,2)`**, **`orders.status ENUM('accepted')`**, **`user_notifications.read_at`**
  (nullable timestamp instead of a boolean) — SQL makes explicit what Firestore left loose.
- **Authorization** has no rules-file equivalent — every `firestore.rules` check becomes hand-written
  API middleware (Phase 3), covered by a per-route × per-role test matrix.

## Things Firebase gave "for free" that need real new work

- Offline write queue/replay → client SQLite **outbox** (Phase 9b; scoped to chat messages +
  like/save for v1, idempotency-keyed).
- Disk-cache instant-paint → hand-rolled read-side local cache.
- Per-listener query-result diffing → hand-written list-channel membership (chat lists only).
- Zero server ops → the team now owns MySQL backups, patching, TLS, on-call. Backup-restore drill
  required before cutover.
- FCM itself is **not** a gap — purely relocated into the Node process.

## Local dev

```bash
cd server
cp .env.example .env        # fill DATABASE_URL, JWT_SECRET, etc.
npm install
npm run prisma:generate
npm run prisma:migrate      # creates tables against DATABASE_URL
npm run dev                 # tsx watch on src/index.ts
```
