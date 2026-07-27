import { NextResponse } from "next/server";
import { ApiError, callApi } from "@/lib/apiClient";
import { setAuthCookies } from "@/lib/authCookies";

interface OtpVerifyResponse {
  accessToken: string;
  refreshToken: string;
  user: { id: string; phone: string; role: string };
}

// Two-step phone+OTP login (superadmin now uses the same auth system
// everyone else does — see docs/07_MIGRATION.md Phase 8). "send" just
// forwards to the real API; "verify" additionally checks role==='superadmin'
// before setting any cookie, matching the old email/password flow's
// same-shaped 403 for a real-but-non-superadmin account.
export async function POST(request: Request) {
  const body = await request.json();
  const step = body?.step;

  if (step === "send") {
    const phone = body?.phone;
    if (!phone || typeof phone !== "string") {
      return NextResponse.json({ error: "phone is required" }, { status: 400 });
    }
    try {
      const result = await callApi("/auth/otp/send", { method: "POST", body: { phone } });
      return NextResponse.json(result);
    } catch (err) {
      if (err instanceof ApiError) return NextResponse.json(err.body, { status: err.status });
      throw err;
    }
  }

  if (step === "verify") {
    const { phone, code } = body ?? {};
    if (!phone || !code) {
      return NextResponse.json({ error: "phone and code are required" }, { status: 400 });
    }

    let result: OtpVerifyResponse;
    try {
      result = await callApi<OtpVerifyResponse>("/auth/otp/verify", {
        method: "POST",
        body: { phone, code },
      });
    } catch (err) {
      if (err instanceof ApiError) return NextResponse.json(err.body, { status: err.status });
      throw err;
    }

    if (result.user.role !== "superadmin") {
      // Don't leave the session row the verify call above just created lying
      // around unused — matches the old flow's client-side signOut() on a
      // rejected non-superadmin login.
      await callApi("/auth/logout", {
        method: "POST",
        body: { refreshToken: result.refreshToken },
      }).catch(() => {});
      return NextResponse.json({ error: "forbidden" }, { status: 403 });
    }

    const res = NextResponse.json({ success: true });
    setAuthCookies(res, result.accessToken, result.refreshToken);
    return res;
  }

  return NextResponse.json({ error: "invalid step" }, { status: 400 });
}
