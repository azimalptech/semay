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
