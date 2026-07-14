# CLAUDE.md — Project context for Claude Code

This file is auto-read by Claude Code at session start. Keep it short; detailed specs live in `/docs`.

## What this project is
SeMay — Instagram-style mobile app (Flutter, Android+iOS) + Firebase backend + Next.js Super Admin
web panel. Full product spec, architecture, data model, Cloud Functions API, screen map, and roadmap
are in `/docs` — **read the relevant doc before implementing anything in that area**:

- `docs/00_PROJECT_OVERVIEW.md` — roles, capabilities, confirmed decisions, open items
- `docs/01_ARCHITECTURE.md` — Flutter + Firebase architecture, custom OTP auth design
- `docs/02_DATA_MODEL.md` — Firestore collections/schema (source of truth for all models)
- `docs/03_CLOUD_FUNCTIONS_API.md` — every backend function/trigger and its contract
- `docs/04_SCREENS_AND_NAVIGATION.md` — Figma screen → app route mapping
- `docs/05_ROADMAP.md` — build phases, current phase

## Repo layout
```
mobile/       Flutter app (User + Store Admin, one codebase, role-branched)
backend/      Firebase project: functions/, firestore.rules, firestore.indexes.json, storage.rules
web-admin/    Next.js Super Admin panel
docs/         Specs (read before coding — see above)
```

## Ground rules for Claude Code in this repo
1. **Don't invent product decisions.** If something in `/docs` is marked as an assumption or "Open
   Item" and the current task depends on it, stop and ask rather than guessing.
2. **Data model is fixed** in `docs/02_DATA_MODEL.md` — don't add/rename Firestore fields without
   updating that doc in the same change.
3. **Auth is custom OTP, not Firebase Phone Auth** — see `docs/01_ARCHITECTURE.md` §2. Don't
   introduce `signInWithPhoneNumber` anywhere.
4. **State management:** Riverpod (assumption flagged in docs — confirm with the user if not yet
   settled before scaffolding a lot of code around it).
5. Keep Cloud Functions in `backend/functions`, one file per function/trigger group, matching the
   names in `docs/03_CLOUD_FUNCTIONS_API.md` exactly so the spec and code stay traceable to each other.

## Current phase
See `docs/05_ROADMAP.md` — we are at **Phase 0 (foundations)**, pending confirmation of the Open
Items listed in `docs/00_PROJECT_OVERVIEW.md` §7.
