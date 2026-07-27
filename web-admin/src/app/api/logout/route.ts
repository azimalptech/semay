import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { callApi } from "@/lib/apiClient";
import { clearAuthCookies, REFRESH_COOKIE } from "@/lib/authCookies";

export async function POST() {
  const refreshToken = (await cookies()).get(REFRESH_COOKIE)?.value;
  if (refreshToken) {
    await callApi("/auth/logout", { method: "POST", body: { refreshToken } }).catch(() => {});
  }

  const res = NextResponse.json({ success: true });
  clearAuthCookies(res);
  return res;
}
