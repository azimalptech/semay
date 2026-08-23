# CLAUDE.md — Project context for Claude Code

This file is auto-read by Claude Code at session start. Keep it short; detailed specs live in `/docs`.

## What this project is
SeMay — Instagram-style mobile app (Flutter, Android+iOS) + a **self-hosted Node/MySQL API** + Next.js
Super Admin web panel. Full product spec, architecture, data model, API, screen map, and roadmap are in
`/docs` — **read the relevant doc before implementing anything in that area**:

- `docs/00_PROJECT_OVERVIEW.md` — roles, capabilities, confirmed decisions, open items
- `docs/01_ARCHITECTURE.md` — architecture, custom OTP auth design
- `docs/02_DATA_MODEL.md` — entity/field reference and the rationale behind every field
- `docs/03_CLOUD_FUNCTIONS_API.md` — historical: the retired Firebase function contracts
- `docs/04_SCREENS_AND_NAVIGATION.md` — Figma screen → app route mapping
- `docs/05_ROADMAP.md` — build phases, current phase
- `docs/07_MIGRATION.md` — **the live architecture reference.** Firebase → MySQL migration, phase by
  phase. Read this before anything backend-shaped; it supersedes 01/02/03 wherever they disagree.
- `docs/08_OPERATIONS.md` — **read before touching deployment, scaling, or auth/media security.**
  Topology, the 100k-DAU requirements, the maintenance reaper, and the reasoning behind each
  hardening decision.
- `docs/09_DEPLOYMENT.md` — step-by-step deployment/redeploy checklist (setup, env vars, Windows
  service, backups, health checks). The *what to type*; 08 is the *why*.

## Repo layout
```
mobile/       Flutter app (User + Store Admin, one codebase, role-branched)
server/       Self-hosted API: Fastify + ws + Prisma/MySQL. The backend.
web-admin/    Next.js Super Admin panel (direct Prisma reads + proxied mutations)
docs/         Specs (read before coding — see above)
```

## Ground rules for Claude Code in this repo
1. **Don't invent product decisions.** If something in `/docs` is marked as an assumption or "Open
   Item" and the current task depends on it, stop and ask rather than guessing.
2. **Schema is fixed** in `server/prisma/schema.prisma` (mirrored into `web-admin/prisma/` by
   `sync-schema.mjs` — never hand-edit that copy). Don't add/rename fields without updating
   `docs/02_DATA_MODEL.md` in the same change.
3. **Auth is custom phone OTP** for mobile and every non-superadmin path —
   `server/src/auth/`. Access JWT (15 min) + opaque rotating refresh token. The
   **superadmin panel is the one exception**: phone + password
   (`users.passwordHash`, bcrypt) via `POST /auth/superadmin/login` — see
   `docs/08_OPERATIONS.md` §9 for why and what guards it. Don't add password
   login anywhere else without the same explicit ask.
4. **Firebase is FCM push only.** `server/src/lib/firebaseAdmin.ts` and `notifications/push.ts` on the
   server, `firebase_core` + `firebase_messaging` in the app. Never reintroduce Firestore, Firebase
   Auth, Firebase Storage, or Cloud Functions.
5. **Media lives on local disk**, not Firebase Storage or MinIO — `server/media/`, served at
   `/media/*`, written via the signed `PUT /api/v1/media/blob/*` flow in `server/src/media/`.
6. **State management:** Riverpod.
7. Authorization is hand-written middleware (`server/src/auth/authz.ts`), not a rules file — every
   route change needs a matching case in `server/tests/authz.matrix.test.ts`.
8. **Realtime goes through `server/src/realtime/bus.ts` only** — never import an emitter or Redis
   client directly. That seam is what lets the app run as multiple processes.
9. **Verify by booting, not just by `inject()`.** The test suite uses Fastify's `inject()`, which
   never exercises the real listener or the static-file stream — a crash-on-first-media-request bug
   passed both typecheck and all tests. Boot the server and curl the affected path.

## Current phase
See `docs/07_MIGRATION.md` — Phases 1–9b are done, plus a hardening/scaling pass (see
`docs/08_OPERATIONS.md`). Remaining: **Phase 10** — load test, backup-restore drill, on-device
matrix, cutover.
