import { NextResponse, type NextRequest } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { prisma } from "@/lib/db";

export async function GET(request: NextRequest) {
  // proxy.ts already gates /api/users/:path* optimistically — this is the
  // secure re-check (fresh DB read) before touching the DB.
  const claims = await getSessionClaims();
  if (!claims) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const phone = request.nextUrl.searchParams.get("phone")?.trim();
  if (!phone) {
    return NextResponse.json({ error: "phone is required" }, { status: 400 });
  }

  // users.phone is UNIQUE — no ambiguity handling needed (the old Firestore
  // lookup here had to reject a multi-match case; that's now structurally
  // impossible, see docs/07_MIGRATION.md).
  const user = await prisma.user.findUnique({ where: { phone } });
  if (!user) {
    return NextResponse.json({ error: "not found" }, { status: 404 });
  }

  return NextResponse.json({ uid: user.id, name: user.name, phone: user.phone });
}
