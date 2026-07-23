import { NextResponse, type NextRequest } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { adminDb } from "@/lib/firebaseAdmin";

export async function GET(request: NextRequest) {
  // proxy.ts already gates /api/users/:path* optimistically — this is the
  // secure re-check (checkRevoked: true) before touching Firestore.
  const claims = await getSessionClaims();
  if (!claims) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const phone = request.nextUrl.searchParams.get("phone")?.trim();
  if (!phone) {
    return NextResponse.json({ error: "phone is required" }, { status: 400 });
  }

  // Resolve exactly the way verifyOtp.ts does on login (backend/functions/
  // src/auth/verifyOtp.ts) — a Firestore `where("phone", "==", ...)` query
  // is the actual identity source of truth for the real OTP flow now.
  //
  // This used to prefer a "<digits>@dev.semay.local" Auth-email lookup, a
  // convention from an earlier client-side dev-bypass that has since been
  // removed from the app entirely (auth_service.dart now calls the real
  // verifyOtp Cloud Function). Keeping that path was actively harmful, not
  // just dead: any stale "@dev.semay.local" Auth account (leftover test
  // data) would win over the real, currently-signed-in user, silently
  // mis-targeting promotions — and since nothing stops a client from
  // updating their own Auth email, an attacker could deliberately set their
  // account's email to "<victim's digits>@dev.semay.local" to hijack a
  // lookup meant for that victim and get promoted in their place.
  const snap = await adminDb.collection("users").where("phone", "==", phone).get();
  if (snap.empty) {
    return NextResponse.json({ error: "not found" }, { status: 404 });
  }
  if (snap.size > 1) {
    // Ambiguous — silently picking one risks promoting the wrong account.
    // Surface it instead of guessing; needs manual cleanup in Firestore.
    return NextResponse.json(
      { error: "multiple accounts share this phone number — cannot resolve unambiguously" },
      { status: 409 },
    );
  }

  const doc = snap.docs[0];
  const data = doc.data();
  return NextResponse.json({
    uid: doc.id,
    name: (data.name as string) ?? "",
    phone: (data.phone as string) ?? "",
  });
}
