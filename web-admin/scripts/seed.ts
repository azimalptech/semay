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

const PLAIN_USER_UID = "seed-plain-user-uid";
const PLAIN_USER_PHONE = "+99361112233";
const PLAIN_USER_NAME = "Aylar";

const STORE_ID = "seed-store-lady-shop";

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
    PLAIN_USER_UID,
    { phoneNumber: PLAIN_USER_PHONE },
    { role: "user", storeIds: [] }
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

  await db.collection("users").doc(PLAIN_USER_UID).set({
    name: PLAIN_USER_NAME,
    avatarUrl: "",
    phone: PLAIN_USER_PHONE,
    role: "user",
    storeIds: [],
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
      adminIds: [],
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
    for (const order of orders) {
      await db.collection("orders").add({
        storeId: STORE_ID,
        adminId: SUPERADMIN_UID,
        userId: PLAIN_USER_UID,
        chatId: `${PLAIN_USER_UID}_${STORE_ID}`,
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
  console.log(`Plain user phone (for the promote-admin lookup) → ${PLAIN_USER_PHONE}`);
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
