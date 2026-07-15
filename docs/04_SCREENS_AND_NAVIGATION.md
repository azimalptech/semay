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
| Store Detail (×2 variants) | `/store/:storeId` | Profile: avatar, bio, phone/location, Message+Call, grid/reels tabs |
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
| Store Detail (×2 variants) | `/admin/store/:storeId` | This is the admin's own-store management view when `storeId` is one of their own |
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

## Open UI question
"Support" and "Chat" are separate top-level screens in both sections. My reading: **Chat** = messaging a
specific store's admin (order negotiation), **Support** = contacting app-level/platform support (not
store-specific). Confirm this is correct — if "Support" is actually meant to be something else (e.g.
FAQ, or the same thing as Chat), let me know before I build both flows as distinct features.
