import { NextResponse, type NextRequest } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { prisma } from "@/lib/db";
import { MEDIA_PUBLIC_BASE_URL, writeMediaObject } from "@/lib/media";

const MAX_SIZE = 10 * 1024 * 1024;
// file.type is entirely client-asserted. An allowlist (not just
// startsWith("image/")) matters here specifically because image/svg+xml
// would otherwise pass — SVGs can embed <script>, and this file is served
// back out from a public URL to every mobile client.
const ALLOWED_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

function objectKeyFor(storeId: string): string {
  return `stores/${storeId}/leaderboard-gift.jpg`;
}

export async function POST(request: NextRequest) {
  // getSessionClaims() itself only ever returns non-null for role ===
  // "superadmin" (see lib/session.ts) — no separate role check needed here.
  const claims = await getSessionClaims();
  if (!claims) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const formData = await request.formData();
  const storeId = formData.get("storeId");
  if (typeof storeId !== "string" || !storeId) {
    return NextResponse.json({ error: "storeId is required" }, { status: 400 });
  }
  const store = await prisma.store.findUnique({ where: { id: storeId } });
  if (!store) {
    return NextResponse.json({ error: "store not found" }, { status: 404 });
  }

  const file = formData.get("file");
  if (!(file instanceof File)) {
    return NextResponse.json({ error: "file is required" }, { status: 400 });
  }
  if (!ALLOWED_TYPES.has(file.type)) {
    return NextResponse.json({ error: "file must be a JPEG, PNG, or WebP image" }, { status: 400 });
  }
  if (file.size > MAX_SIZE) {
    return NextResponse.json({ error: "file too large (max 10MB)" }, { status: 400 });
  }

  const bytes = Buffer.from(await file.arrayBuffer());
  const key = objectKeyFor(storeId);
  await writeMediaObject(key, bytes);

  const campaignImageUrl = `${MEDIA_PUBLIC_BASE_URL}/${key}`;
  await prisma.store.update({ where: { id: storeId }, data: { campaignImageUrl } });

  return NextResponse.json({ campaignImageUrl });
}

export async function DELETE(request: NextRequest) {
  const claims = await getSessionClaims();
  if (!claims) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const storeId = request.nextUrl.searchParams.get("storeId");
  if (!storeId) {
    return NextResponse.json({ error: "storeId is required" }, { status: 400 });
  }

  // Not deleting the file on disk is a known, accepted gap here (same as the
  // store cascade-delete not cleaning up media — see docs/07_MIGRATION.md) —
  // only the DB field is cleared; a stale file under stores/{id}/ is harmless.
  await prisma.store.update({ where: { id: storeId }, data: { campaignImageUrl: null } });

  return NextResponse.json({ success: true });
}
