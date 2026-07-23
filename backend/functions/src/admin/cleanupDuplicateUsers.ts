import { onCall, HttpsError } from "firebase-functions/v2/https";
import { db, auth } from "../utils/firebaseAdmin";

interface CleanupRequest {
  confirm?: boolean;
}

interface DuplicateGroup {
  phone: string;
  keepUid: string;
  deleteUids: string[];
  skippedReason?: string;
}

// One-off maintenance: find any phone number owned by more than one users/{uid}
// doc (duplicate accounts from the pre-fix verifyOtp race — see verifyOtp.ts's
// deterministic-uid guarantee, which prevents NEW ones) and remove the extras,
// keeping exactly one account per phone.
//
// Safety:
// - Super-Admin only.
// - Dry-run by default: without { confirm: true } it deletes nothing and just
//   returns the plan (which uid it would keep vs delete per phone).
// - NEVER deletes an admin/store account. The keeper for each phone is chosen
//   as: an admin/store account if present, else one with a non-empty name,
//   else the oldest — and the delete list is additionally filtered to
//   user-role accounts only, so an admin can't be removed even if mis-ranked.
// - If a single phone is shared by 2+ admin/store accounts, the whole group is
//   skipped and flagged for manual review rather than guessed at.
//
// Does not clean up chats/messages/orders that referenced a deleted uid — those
// are left orphaned (harmless: every screen treats a missing user as an empty
// state), same pre-existing gap a normal account removal already leaves.
export const cleanupDuplicateUsers = onCall<CleanupRequest>({ cpu: 1 }, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Must be signed in");
  }
  if (request.auth.token.role !== "superadmin") {
    throw new HttpsError("permission-denied", "Super Admin only");
  }

  const snap = await db.collection("users").get();

  const byPhone = new Map<string, FirebaseFirestore.QueryDocumentSnapshot[]>();
  for (const doc of snap.docs) {
    const phone = doc.data().phone as string | undefined;
    if (!phone) continue;
    const arr = byPhone.get(phone) ?? [];
    arr.push(doc);
    byPhone.set(phone, arr);
  }

  const isAdminish = (d: FirebaseFirestore.DocumentData): boolean =>
    (typeof d.role === "string" && d.role !== "user") ||
    (Array.isArray(d.storeIds) && d.storeIds.length > 0);

  const groups: DuplicateGroup[] = [];
  for (const [phone, docs] of byPhone) {
    if (docs.length < 2) continue;

    const admins = docs.filter((d) => isAdminish(d.data()));
    if (admins.length > 1) {
      groups.push({
        phone,
        keepUid: "",
        deleteUids: [],
        skippedReason: "multiple admin/store accounts share this phone — review manually",
      });
      continue;
    }

    const ranked = [...docs].sort((a, b) => {
      const ad = a.data();
      const bd = b.data();
      const aAdmin = isAdminish(ad) ? 1 : 0;
      const bAdmin = isAdminish(bd) ? 1 : 0;
      if (aAdmin !== bAdmin) return bAdmin - aAdmin;
      const aNamed = (ad.name as string | undefined)?.trim() ? 1 : 0;
      const bNamed = (bd.name as string | undefined)?.trim() ? 1 : 0;
      if (aNamed !== bNamed) return bNamed - aNamed;
      const aTime = (ad.createdAt?.toMillis?.() as number | undefined) ?? Number.MAX_SAFE_INTEGER;
      const bTime = (bd.createdAt?.toMillis?.() as number | undefined) ?? Number.MAX_SAFE_INTEGER;
      return aTime - bTime;
    });

    const keep = ranked[0];
    const deleteUids = ranked
      .slice(1)
      .filter((d) => !isAdminish(d.data()))
      .map((d) => d.id);

    groups.push({ phone, keepUid: keep.id, deleteUids });
  }

  const actionable = groups.filter((g) => g.deleteUids.length > 0);
  const wouldDelete = actionable.reduce((n, g) => n + g.deleteUids.length, 0);

  if (request.data?.confirm !== true) {
    return { dryRun: true, duplicatePhones: groups.length, wouldDelete, groups };
  }

  let deleted = 0;
  const errors: string[] = [];
  for (const g of actionable) {
    for (const uid of g.deleteUids) {
      try {
        // Auth user may not exist (e.g. already removed) — don't let that abort.
        await auth.deleteUser(uid).catch(() => undefined);
        await db.collection("users").doc(uid).delete();
        deleted++;
      } catch (e) {
        errors.push(`${uid}: ${(e as Error).message}`);
      }
    }
  }

  return { dryRun: false, deleted, errors, groups };
});
