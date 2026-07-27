import { NextResponse, type NextRequest } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { prisma } from "@/lib/db";

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
    storeIds.some((id) => typeof id !== "string")
  ) {
    return NextResponse.json(
      { error: `storeIds must be 1-${MAX_STORES} store IDs` },
      { status: 400 }
    );
  }

  const count = await prisma.store.count({ where: { id: { in: storeIds } } });
  if (count !== storeIds.length) {
    return NextResponse.json({ error: "one or more storeIds do not exist" }, { status: 400 });
  }

  // Always normalized to sequential integers on save, rather than trying to
  // manage gaps/collisions between arbitrary order values across edits.
  await prisma.$transaction(
    storeIds.map((id, index) =>
      prisma.store.update({ where: { id }, data: { leaderboardOrder: index } })
    )
  );

  return NextResponse.json({ success: true });
}
