# SeMay

Instagram-style store platform: Flutter mobile app (User + Store Admin) + Firebase backend + Next.js
Super Admin web panel.

**Start here:** [`docs/00_PROJECT_OVERVIEW.md`](./docs/00_PROJECT_OVERVIEW.md)

## Working on this repo with Claude Code
Open this folder in VS Code with the Claude Code extension installed. `CLAUDE.md` at the repo root is
read automatically at the start of every session and points to the full specs in `/docs`. Just open a
Claude Code session here and say what you want built next (e.g. "scaffold Phase 0" or "implement the
sendOtp Cloud Function") — it already has the context.

## Folders
| Folder | Contents | Status |
|---|---|---|
| `docs/` | Product spec, architecture, data model, API, screen map, roadmap | ✅ done |
| `mobile/` | Flutter app | ✅ Phase 0 scaffold (routing, theme, folder structure, Riverpod) |
| `backend/` | Firebase project (Functions, Firestore rules, Storage rules) | ✅ Phase 0 scaffold (`sendOtp`/`verifyOtp`, rules v1, emulators) |
| `web-admin/` | Next.js Super Admin panel | ⏳ not yet scaffolded (Phase 4) |

## Before building further
A handful of "Open Items" in `docs/00_PROJECT_OVERVIEW.md` §7 (story expiry, video size caps, comment
moderation, order status workflow, store categories, localization, notification scope) don't block the
Phase 0 scaffold but do need answers before Phase 2+. Also still needed: a real Firebase project linked
via `firebase use --add` + `flutterfire configure` (both require your Firebase console login), and the
actual Figma theme tokens (colors/typography) to replace the placeholders in `mobile/lib/core/theme.dart`.
