import { NextResponse } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { prisma } from "@/lib/db";

export async function POST(request: Request) {
  const claims = await getSessionClaims();
  if (!claims) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const body = await request.json();
  const storeId = body?.storeId;
  const startAtMillis = body?.startAtMillis;
  // Optional campaign end: a number sets it, explicit null clears it (open-
  // ended), omitting the field leaves it untouched.
  const endAtMillis = body?.endAtMillis;
  if (typeof storeId !== "string" || typeof startAtMillis !== "number") {
    return NextResponse.json({ error: "storeId and startAtMillis are required" }, { status: 400 });
  }
  if (endAtMillis !== undefined && endAtMillis !== null && typeof endAtMillis !== "number") {
    return NextResponse.json({ error: "endAtMillis must be a number or null" }, { status: 400 });
  }
  if (typeof endAtMillis === "number" && endAtMillis < startAtMillis) {
    return NextResponse.json({ error: "endAtMillis must be on or after startAtMillis" }, { status: 400 });
  }

  const store = await prisma.store.update({
    where: { id: storeId },
    data: {
      campaignStartAt: new Date(startAtMillis),
      ...(endAtMillis === undefined
        ? {}
        : { campaignEndAt: endAtMillis === null ? null : new Date(endAtMillis) }),
    },
  });

  return NextResponse.json({
    success: true,
    campaignStartAtMillis: store.campaignStartAt!.getTime(),
    campaignEndAtMillis: store.campaignEndAt ? store.campaignEndAt.getTime() : null,
  });
}
