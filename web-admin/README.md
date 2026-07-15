# web-admin/

SeMay's Super Admin panel — Next.js (App Router), separate email/password auth from the mobile app's
phone/OTP flow. See `../docs/01_ARCHITECTURE.md` §8, `../docs/03_CLOUD_FUNCTIONS_API.md`, and
`../docs/04_SCREENS_AND_NAVIGATION.md` for the full spec.

Auth is enforced by `src/proxy.ts` (Next's renamed `middleware.ts`, defaults to the Node.js runtime as
of this Next.js version) on every `/dashboard`, `/stores`, and `/api/users/*` request, plus a second,
"secure" re-check (`src/lib/session.ts`) in the protected layout and each Route Handler — see the
comments in those files for why there are two checks.

## Local dev (against the Firebase emulator suite)

```bash
cp .env.local.example .env.local   # only needed once
npm run seed                        # seeds a Super Admin + a plain user + sample orders
npm run dev
```

Requires the emulator suite running with Functions included (`firebase emulators:start`), and
`createStore`/`setStoreAdmin` built (`npm run build` in `backend/functions`) — this app calls them as
Cloud Functions, same trust model as the mobile app.

`npm run seed` prints the seeded Super Admin's email/password and the plain user's phone number.
