import { NextResponse, type NextRequest } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { adminDb } from "@/lib/firebaseAdmin";

// Firestore auto-generated document IDs are always in this alphabet, never
// containing '/' or empty — anything else can't be a real store ID and
// would otherwise throw when handed to .doc(), turning a bad request into
// an unhandled 500 that also aborts the whole (atomic) batch.
const VALID_ID = /^[A-Za-z0-9_-]{1,128}$/;
const MAX_STORES = 200;

export async function POST(request: NextRequest) {
  // getSessionClaims() itself only ever returns non-null for role ===
  // "superadmin" (see lib/session.ts) — no separate role check needed here.
  const claims = await getSessionClaims();
  if (!claims) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }

  const storeIds = (body as { storeIds?: unknown })?.storeIds;
  if (
    !Array.isArray(storeIds) ||
    storeIds.length === 0 ||
    storeIds.length > MAX_STORES ||
    storeIds.some((id) => typeof id !== "string" || !VALID_ID.test(id))
  ) {
    return NextResponse.json(
      { error: `storeIds must be 1-${MAX_STORES} valid store IDs` },
      { status: 400 },
    );
  }

  // Verify every ID is a real store before touching anything — batch.update()
  // on a nonexistent doc fails as NOT_FOUND at commit time and aborts the
  // whole atomic batch with an opaque 500.
  const refs = storeIds.map((id) => adminDb.collection("stores").doc(id));
  const snaps = await adminDb.getAll(...refs);
  if (snaps.some((snap) => !snap.exists)) {
    return NextResponse.json({ error: "one or more storeIds do not exist" }, { status: 400 });
  }

  // Always normalized to sequential integers on save, rather than trying to
  // manage gaps/collisions between arbitrary order values across edits.
  const batch = adminDb.batch();
  refs.forEach((ref, index) => {
    batch.update(ref, { leaderboardOrder: index });
  });
  await batch.commit();

  return NextResponse.json({ success: true });
}
