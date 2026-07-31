import { NextResponse } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { ApiError, callAuthedApi } from "@/lib/apiClient";

// proxy.ts gates /api/stores/:path* optimistically — this is the secure
// re-check (fresh DB read) before forwarding to the real API, which does its
// own authorization independently (defense in depth, same pattern as every
// other Route Handler here).
export async function POST(request: Request) {
  const claims = await getSessionClaims();
  if (!claims) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await request.json();
  try {
    const result = await callAuthedApi("/stores", { method: "POST", body });
    return NextResponse.json(result, { status: 201 });
  } catch (err) {
    if (err instanceof ApiError) return NextResponse.json(err.body, { status: err.status });
    throw err;
  }
}
