# Screens & Navigation (mapped from the Figma file)

Source: `figma.com/design/OI1BiSUDnZbc7biI19abwD/SeMay`, sections **"User"** (node `214:4532`) and
**"Store Admin"** (node `223:4714`) — the only two sections in scope, per your instruction. (The file
also contains an older, unrelated e-commerce project with cart/category/checkout screens sitting outside
these two sections — explicitly ignored.)

## User app — screen inventory
| Figma frame | App route (proposed) | Notes |
|---|---|---|
| Login Phone Number | `/auth/phone` | |
| Login OTP | `/auth/otp` | Calls `verifyOtp` |
| Login Name | `/auth/name` | Only shown if `isNewUser` |
| Homepage (×3 variants) | `/home` | Global discovery feed + stories bar at top |
| Homepage Story | `/home/story/:storeId` | Full-screen story viewer |
| Store Detail (×2 variants) | `/store/:storeId` | Profile: avatar, bio, phone/location, Message+Call, grid/reels tabs. The avatar's story ring follows the home bar's rule — gradient while the store has an active (unexpired, by the server's `expiresAt`) story the viewer has not watched through, muted once all are watched, **no ring** when there is no active story; tap opens the story viewer (`/home/story/:storeId`). The ring drops on its own when the last story expires while the screen is open, and re-reads on app resume. |
| Chat | `/chat/:chatId` | |
| Support / Support Send | `/support` | App-level help/contact — **not the same as store chat**, confirm this distinction is what you intend |
| Profile | `/profile` | |
| Profile Notifications | `/profile/notifications` | |
| Liked | `/profile/liked` | |
| Saved | `/profile/saved` | |

## Store Admin app — screen inventory
| Figma frame | App route (proposed) | Notes |
|---|---|---|
| Login Phone Number / OTP / Name | same as User | Shared login flow — role/claim decides which mode loads after |
| Homepage (×3 variants) | `/admin/home` | Admin can browse like a normal user too |
| Homepage Story | `/admin/home/story/:storeId` | |
| Store Detail (×2 variants) | `/admin/store/:storeId` | This is the admin's own-store management view when `storeId` is one of their own. Same story-ring rule as the user variant (viewer route `/admin/home/story/:storeId`); the own store shows no ring until it has published a story — only the "+" badge, and tapping the ringless avatar opens the add-story sheet. Edit Profile (`/admin/store/:storeId/edit`) confirms a save with "Üýtgeşmeler ýatda saklandy" on the profile it returns to, shows a localised reason on failure, and withholds Save while the name is empty/over 120 characters or an avatar upload is in flight |
| Reels | `/admin/reels` | Browse/manage reels |
| MyReel | `/admin/reels/mine` | This store's own reels |
| Chat | `/admin/chat/:chatId` | Includes the **"kabul edildi"** button above the composer |
| Support / Support Send | `/admin/support` | |
| Settings (×3 variants) | `/admin/settings` | Store profile edit, account settings |
| Notifications | `/admin/notifications` | |
| Liked / Saved | `/admin/liked`, `/admin/saved` | Admin's personal likes/saves (as a browsing user) |

## Super Admin web — screen inventory (not in Figma — new, web-only)
| Page | Purpose |
|---|---|
| `/login` | Super Admin auth (proposal: email/password, separate from phone OTP — flag if wrong) |
| `/dashboard` | Read-only order report: total item quantity per day, per store. No status (every order is `accepted`), no per-order actions — Super Admin can't edit or approve anything here. |
| `/stores` | List + create stores |
| `/stores/:id/admins` | Promote/revoke admin privileges for existing user accounts |

## Navigation/role-branching logic
On login, after `verifyOtp` resolves and (if new) `completeProfile` runs:
- Read the user's custom claims.
- `role == 'user'` → route to `/home`.
- `role == 'admin'` → route to `/admin/home`. If they belong to multiple stores, show a store switcher
  (not present in the Figma screens you gave me — **flag if a multi-store admin needs a picker UI**,
  since "Choose store" exists in the file but outside your scoped sections).
- Super Admin never uses the Flutter app at all — web only.

## Share links (deep links into the app)
Every OS-share action — a post card's share arrow, the post detail's share button, the reel rail's
share, and both share entry points on a store profile — hands the sheet a public **https** link as
text with a title (`mobile/lib/core/share_links.dart`), never a bare custom-scheme string (the old
`semay://post/<id>` reached recipients as an inert string while the share still got counted):

| Link | Opens | In-app route pushed |
|---|---|---|
| `https://semaycollection.com/p/:postId` | image / carousel post | `/post/:postId` (`PostDetailScreen`) |
| `https://semaycollection.com/r/:postId` | reel | `/post/:postId` — the detail screen switches to the full-screen player by post type |
| `https://semaycollection.com/s/:storeId` | store profile | `/store/:storeId` (`StoreProfileScreen`) |
| `semay://open/p/:id`, `/r/:id`, `/s/:id` | the same three | the same — the custom-scheme mirror the share page's "Open in SeMay" button uses (fixed host `open` so the engine forwards `/p/:id`, which go_router matches; the kind must not sit in the host) |
| `semay://post/:id`, `semay://store/:id` | the same | legacy Phase 1 shapes — still parsed for links already in the wild, never emitted |

`www.semaycollection.com` is accepted too. The `:id` in every row is validated
as a **UUID**, the same shape `server/src/share/routes.ts` enforces: once App
Links verify, the app intercepts these URLs, so a looser parser would push a
detail screen for a post that cannot exist instead of letting the browser show
the server's own "Salgy tapylmady" page.

The Android intent-filter for `semay://` is **scheme-only, with no
`android:host`** — with `host="open"` the two legacy rows were dead on Android
(the OS never started the activity for them) while iOS honoured them, so the
platforms disagreed about a documented behaviour. `open` remains the dummy host
the app *emits*, because the engine forwards `uri.path` and the kind must not
sit in the host.

**A link the app claims but cannot parse is a no-op, never a navigation.** The
manifest's `autoVerify` filter claims every path merely *starting* with `/p/`,
`/r/` or `/s/`, and the scheme filter claims `semay://` unconstrained — a much
wider space than `parseIncomingLink` accepts (`/p/` alone, `/p/<id>/extra`, a
link with trailing prose punctuation, a non-UUID id). Once App Links verify,
Android delivers all of it with no chooser, so `router.dart` swallows the gap:
`handleWarmLink` returns true without touching the stack for any URI
`isOwnShareUri` recognises, and the router carries an `onException` that sends
an unmatched cold-start location to the shell root. Letting either fall through
to go_router replaced the whole configuration and left the user on the default
"Page Not Found" screen with an empty stack — no AppBar, no back, no shell.
Pinned by `mobile/test/core/deep_link_router_test.dart`.

**Every share button reports back** (`showShareOutcome` in
`post_interaction_providers.dart`, used by the post/reel icons and by
`shareStore`): a completed share confirms with `postShared`, a dismissal stays
silent because it was deliberate, and a sheet that could never be presented —
the iPad no-anchor case `shareOriginOf` explicitly allows — shows `shareFailed`
naming the reason. The store share used to show nothing at all in either case.

**The emitted origin is always one of those hosts.** It comes from `API_BASE_URL` only when that
host is already in `shareHosts`; otherwise it falls back to `https://semaycollection.com`
(`SHARE_SITE_ORIGIN` overrides both). A link is consumed on *someone else's* phone by an OS that
only recognises those hosts, so a build made without `--dart-define=API_BASE_URL` — every debug
build, and any mis-built release — must not hand recipients `http://localhost:8080/p/<id>`: not
https, not reachable, not an App Link, and the share sheet looks identical either way. A dev build
can still be deep-linked at its own server: `parseIncomingLink` additionally accepts the API's own
host.

The shared **text** is `headline`, the post caption (whitespace-collapsed, capped at 200 chars)
when there is one, then the link on its own last line, with `headline` as the sheet's title and
subject. The caption is deliberate — it is what makes the message readable in WhatsApp, where the
link preview itself is generic — and is *not* a leak: the sharer chose to share that post. Store
shares carry no caption.

Routing (`mobile/lib/core/router.dart`): `/p/:id`, `/r/:id`, `/s/:id` exist as `GoRoute`s so
go_router can match the incoming URI at all, but they are **never a resting location** — a link
opened straight onto one of them would have no shell underneath (back would exit the app).

- **Cold start** (the engine reports the URI as the initial route) and **cold start behind login**:
  `redirect` parks the target and sends the router through its normal gates (splash → shell, or
  splash → `/auth/*` → shell once logged in); the moment the shell root is the current location the
  target is **pushed on top of it**, so back returns to the shell.
- **Warm** (`onNewIntent` / `openURL` → `pushRouteInformation`): intercepted by a
  `WidgetsBindingObserver` *before* go_router's own route-information provider sees it, and pushed
  straight onto the live stack. This is load-bearing, not an optimisation: `Router` answers a
  platform route with `setNewRoutePath`, which **replaces the whole configuration** — a user three
  screens deep who tapped a SeMay link in WhatsApp lost every screen in between. Now the prior
  stack survives and back returns to exactly where they were, as it does in WhatsApp and Instagram.
  A warm link arriving while still on splash or in the login flow is parked instead, and dispatched
  by the same path as a cold start.

Store shares are not counted; a post share counts only when the sheet reports a completed share
(`docs/02`). A share sheet that fails to present at all (share_plus raises on iPad without a
popover anchor) degrades to "not shared" — it never escapes the button's `onPressed`.

Platform registration: `AndroidManifest.xml` (`flutter_deeplinking_enabled`, VIEW/BROWSABLE
`semay://open`, and an `autoVerify` https filter for both hosts with `/p/` `/r/` `/s/` prefixes),
`Info.plist` (`CFBundleURLTypes` scheme `semay`, `FlutterDeepLinkingEnabled`). No iOS
associated-domains entitlement yet — portal work, see `docs/09_DEPLOYMENT.md` §5e.

## Open UI question
"Support" and "Chat" are separate top-level screens in both sections. My reading: **Chat** = messaging a
specific store's admin (order negotiation), **Support** = contacting app-level/platform support (not
store-specific). Confirm this is correct — if "Support" is actually meant to be something else (e.g.
FAQ, or the same thing as Chat), let me know before I build both flows as distinct features.
