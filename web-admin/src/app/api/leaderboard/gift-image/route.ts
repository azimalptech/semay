import { randomUUID } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { adminDb, adminStorage, bucketName } from "@/lib/firebaseAdmin";

const MAX_SIZE = 10 * 1024 * 1024;
// file.type is entirely client-asserted. An allowlist (not just
// startsWith("image/")) matters here specifically because image/svg+xml
// would otherwise pass — SVGs can embed <script>, and this file is served
// back out from a public, tokened URL to every mobile client.
const ALLOWED_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
// Matches the storeId shape enforced in store-order/route.ts — Firestore
// auto-IDs, never attacker-controlled path traversal.
const STORE_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

function storagePathFor(storeId: string): string {
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
  if (typeof storeId !== "string" || !STORE_ID_PATTERN.test(storeId)) {
    return NextResponse.json({ error: "storeId is required" }, { status: 400 });
  }
  const storeSnap = await adminDb.collection("stores").doc(storeId).get();
  if (!storeSnap.exists) {
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
  const bucket = adminStorage.bucket(bucketName);
  const storageFile = bucket.file(storagePathFor(storeId));
  const downloadToken = randomUUID();
  await storageFile.save(bytes, {
    contentType: file.type,
    metadata: { metadata: { firebaseStorageDownloadTokens: downloadToken } },
  });

  const campaignImageUrl = `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/${encodeURIComponent(
    storagePathFor(storeId),
  )}?alt=media&token=${downloadToken}`;

  await adminDb.collection("stores").doc(storeId).update({ campaignImageUrl });

  return NextResponse.json({ campaignImageUrl });
}

export async function DELETE(request: NextRequest) {
  const claims = await getSessionClaims();
  if (!claims) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const storeId = request.nextUrl.searchParams.get("storeId");
  if (!storeId || !STORE_ID_PATTERN.test(storeId)) {
    return NextResponse.json({ error: "storeId is required" }, { status: 400 });
  }

  const bucket = adminStorage.bucket(bucketName);
  await bucket.file(storagePathFor(storeId)).delete({ ignoreNotFound: true });
  await adminDb.collection("stores").doc(storeId).update({ campaignImageUrl: null });

  return NextResponse.json({ success: true });
}
