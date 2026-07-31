import { NextResponse } from "next/server";
import { ApiError, callApi } from "@/lib/apiClient";
import { setAuthCookies } from "@/lib/authCookies";

interface LoginResponse {
  accessToken: string;
  refreshToken: string;
  user: { id: string; phone: string; role: string };
}

// Password login for the Super Admin panel, at the owner's explicit request
// (2026-07-30) — see server/src/auth/superadminAuth.ts for the full rationale.
// This replaces the two-step phone+OTP flow web-admin used previously; the
// server's OTP endpoints are untouched and still serve the mobile app.
export async function POST(request: Request) {
  const body = await request.json();
  const { phone, password } = body ?? {};
  if (!phone || typeof phone !== "string" || !password || typeof password !== "string") {
    return NextResponse.json({ error: "phone and password are required" }, { status: 400 });
  }

  let result: LoginResponse;
  try {
    result = await callApi<LoginResponse>("/auth/superadmin/login", {
      method: "POST",
      body: { phone, password },
    });
  } catch (err) {
    if (err instanceof ApiError) return NextResponse.json(err.body, { status: err.status });
    throw err;
  }

  const res = NextResponse.json({ success: true });
  setAuthCookies(res, result.accessToken, result.refreshToken);
  return res;
}
