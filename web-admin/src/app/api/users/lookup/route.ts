import { NextResponse, type NextRequest } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { adminAuth, adminDb } from "@/lib/firebaseAdmin";

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

  // Prefer the uid the mobile app's own dev-mode OTP bypass actually signs
  // into (mobile/lib/services/auth_service.dart's verifyOtp): phone digits
  // -> a deterministic "<digits>@dev.semay.local" Auth account. Falling
  // straight to a `where("phone", "==", ...)` Firestore query is what broke
  // this before — that collection has accumulated duplicate docs sharing a
  // phone (this dev-bypass replaced an earlier phone-auth-style scheme, and
  // old seed/test records were never cleaned up), so a plain lookup with no
  // tiebreaker can silently resolve to a uid nobody is actually signed in
  // as, and granting admin there has no visible effect for the real user.
  const digits = phone.replace(/[^0-9]/g, "");
  try {
    const authUser = await adminAuth.getUserByEmail(`${digits}@dev.semay.local`);
    const doc = await adminDb.collection("users").doc(authUser.uid).get();
    return NextResponse.json({
      uid: authUser.uid,
      name: (doc.data()?.name as string) ?? "",
      phone,
    });
  } catch {
    // Not a dev-bypass account (e.g. seeded directly via the Admin SDK) —
    // fall back to the Firestore phone field.
  }

  const snap = await adminDb.collection("users").where("phone", "==", phone).limit(1).get();
  if (snap.empty) {
    return NextResponse.json({ error: "not found" }, { status: 404 });
  }

  const doc = snap.docs[0];
  const data = doc.data();
  return NextResponse.json({
    uid: doc.id,
    name: (data.name as string) ?? "",
    phone: (data.phone as string) ?? "",
  });
}
