# SeMay

Instagram-style store platform: Flutter mobile app (User + Store Admin) + a self-hosted Node/MySQL API
+ Next.js Super Admin web panel. Firebase is used for FCM push notifications only.

**Start here:** [`docs/00_PROJECT_OVERVIEW.md`](./docs/00_PROJECT_OVERVIEW.md) for the product,
[`docs/07_MIGRATION.md`](./docs/07_MIGRATION.md) for the current architecture.

## Working on this repo with Claude Code
Open this folder in VS Code with the Claude Code extension installed. `CLAUDE.md` at the repo root is
read automatically at the start of every session and points to the full specs in `/docs`.

## Folders
| Folder | Contents | Status |
|---|---|---|
| `docs/` | Product spec, architecture, data model, API, screen map, roadmap, migration log | ✅ |
| `server/` | Self-hosted API (Fastify + ws + Prisma/MySQL), local media storage, FCM sender | ✅ Phases 1–9b |
| `mobile/` | Flutter app (REST + WebSocket client, offline outbox, read cache) | ✅ Phase 9b |
| `web-admin/` | Next.js Super Admin panel | ✅ Phase 8 |

## Local dev
Requires MySQL 8 (XAMPP is fine) and Node ≥ 20.6.

```bash
cd server
cp .env.example .env        # fill DATABASE_URL, JWT_SECRET, etc.
npm install
npm run prisma:generate
npm run prisma:migrate      # creates tables against DATABASE_URL
npm run dev                 # http://localhost:8080
```

Then `cd web-admin && npm install && npm run dev` (http://localhost:3000), and
`cd mobile && flutter pub get && flutter run`.

Uploaded media is written to `server/media/` and served at `/media/*`. Logs are written as
newline-delimited JSON to `server/logs/app.<date>.log`, rotated daily. Both are gitignored.

## Before launch
Phase 10 in [`docs/07_MIGRATION.md`](./docs/07_MIGRATION.md): staging rehearsal, the on-device test
matrix (including the offline outbox replay loop), a backup-restore drill, and cutover. Also still
open: the "Open Items" in `docs/00_PROJECT_OVERVIEW.md` §7.
