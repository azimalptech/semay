// Seeds the local Firebase emulator suite with:
// - one Super Admin (email/password) to log into web-admin with
// - one plain user (phone-identified) to promote to store-admin in the click-through
// - one baseline store with sample orders across 2 days, so /dashboard has data
// Run with `npm run seed` while the emulator suite (auth+firestore+functions) is up.
process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8080";
process.env.FIREBASE_AUTH_EMULATOR_HOST = "127.0.0.1:9099";

import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore, Timestamp, FieldValue } from "firebase-admin/firestore";

initializeApp({ projectId: "demo-semay" });
const auth = getAuth();
const db = getFirestore();

const SUPERADMIN_UID = "seed-superadmin-uid";
const SUPERADMIN_EMAIL = "superadmin@semay.local";
const SUPERADMIN_PASSWORD = "superadmin123";

// No fixed-uid "plain user" account is seeded anymore — it used to be
// created via a phoneNumber-style Auth account, but the mobile app's dev
// OTP bypass (auth_service.dart) now signs in with a deterministic
// "<digits>@dev.semay.local" email/password account instead. Seeding a
// second, differently-authed account for the same phone number produced two
// Firestore users/{uid} docs sharing one `phone` — /api/users/lookup had no
// tiebreaker between them, so a promote-to-admin could silently land on the
// uid nobody was actually signed in as. Just use the phone in the mobile
// app; its first real login creates the Firestore doc.
const PLAIN_USER_PHONE = "+99361112233";

const STORE_ID = "seed-store-lady-shop";

// Store-admin test account, pre-provisioned with custom claims already set
// (mobile/lib/services/auth_service.dart's dev OTP-bypass signs in with
// email/password, which — unlike the real verifyOtp Cloud Function — never
// calls the Admin SDK, so it can never mint role/storeIds custom claims on
// its own. Logging in with this phone number in the app hits this
// already-provisioned account instead of creating a fresh claim-less one.)
const STORE_ADMIN_UID = "seed-store-admin-uid";
const STORE_ADMIN_PHONE = "+99365555555";
const STORE_ADMIN_NAME = "Store Admin";
// Must match the digits + "@dev.semay.local" convention and fixed password
// in auth_service.dart's _devEmailFor()/verifyOtp().
const STORE_ADMIN_EMAIL = "99365555555@dev.semay.local";
const DEV_BYPASS_PASSWORD = "dev-testing-password-123";

function dayTimestamp(daysAgo: number, hour: number): Timestamp {
  const d = new Date();
  d.setDate(d.getDate() - daysAgo);
  d.setHours(hour, 0, 0, 0);
  return Timestamp.fromDate(d);
}

async function ensureAuthUser(
  uid: string,
  props: { email?: string; password?: string; phoneNumber?: string },
  claims: Record<string, unknown>
) {
  try {
    await auth.getUser(uid);
  } catch {
    await auth.createUser({ uid, ...props });
  }
  await auth.setCustomUserClaims(uid, claims);
}

async function main() {
  await ensureAuthUser(
    SUPERADMIN_UID,
    { email: SUPERADMIN_EMAIL, password: SUPERADMIN_PASSWORD },
    { role: "superadmin" }
  );
  await ensureAuthUser(
    STORE_ADMIN_UID,
    { email: STORE_ADMIN_EMAIL, password: DEV_BYPASS_PASSWORD },
    { role: "admin", storeIds: [STORE_ID] }
  );

  await db.collection("users").doc(SUPERADMIN_UID).set({
    name: "Super Admin",
    avatarUrl: "",
    phone: "",
    role: "superadmin",
    storeIds: [],
    fcmTokens: [],
    createdAt: FieldValue.serverTimestamp(),
  });

  await db.collection("users").doc(STORE_ADMIN_UID).set({
    name: STORE_ADMIN_NAME,
    avatarUrl: "",
    phone: STORE_ADMIN_PHONE,
    role: "admin",
    storeIds: [STORE_ID],
    fcmTokens: [],
    createdAt: FieldValue.serverTimestamp(),
  });

  const storeSnap = await db.collection("stores").doc(STORE_ID).get();
  if (!storeSnap.exists) {
    await db.collection("stores").doc(STORE_ID).set({
      name: "Lady's shop",
      tagline: "Feel Beautiful, Always. ✨",
      avatarUrl: "",
      coverUrl: "",
      phone: "+99362123456",
      address: "Ashgabat, Bitaraplyk shayoly 142-nji jayy",
      geopoint: null,
      adminIds: [STORE_ADMIN_UID],
      postsCount: 0,
      reelsCount: 0,
      createdBy: SUPERADMIN_UID,
      createdAt: FieldValue.serverTimestamp(),
      active: true,
    });

    const orders = [
      { itemQuantity: 3, createdAt: dayTimestamp(1, 10) },
      { itemQuantity: 2, createdAt: dayTimestamp(1, 15) },
      { itemQuantity: 5, createdAt: dayTimestamp(0, 11) },
    ];
    // Sample rows for the dashboard's orders report only — deliberately not
    // tied to any real uid (see the note above on why a second seeded
    // account for the same phone caused real bugs).
    for (const order of orders) {
      await db.collection("orders").add({
        storeId: STORE_ID,
        adminId: SUPERADMIN_UID,
        userId: "demo-customer",
        chatId: null,
        itemQuantity: order.itemQuantity,
        userPhone: PLAIN_USER_PHONE,
        status: "accepted",
        createdAt: order.createdAt,
        updatedAt: order.createdAt,
      });
    }
  }

  console.log("Seed complete.");
  console.log(`Super Admin login → email: ${SUPERADMIN_EMAIL}  password: ${SUPERADMIN_PASSWORD}`);
  console.log(`Store-admin phone (already has admin claims on "${STORE_ID}") → ${STORE_ADMIN_PHONE}`);
  console.log(
    `To test promote-to-admin: log into the mobile app with any phone number first (creates its Firestore user doc), then promote that number from the Stores > Manage Admins page.`
  );
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
