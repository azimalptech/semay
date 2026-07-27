import { NextResponse } from "next/server";
import { getSessionClaims } from "@/lib/session";
import { getAccessToken } from "@/lib/accessToken";
import { ApiError, callApi } from "@/lib/apiClient";

export async function POST(request: Request) {
  const claims = await getSessionClaims();
  if (!claims) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await request.json();
  try {
    const result = await callApi("/notifications/broadcast", {
      method: "POST",
      body,
      accessToken: await getAccessToken(),
    });
    return NextResponse.json(result);
  } catch (err) {
    if (err instanceof ApiError) return NextResponse.json(err.body, { status: err.status });
    throw err;
  }
}
