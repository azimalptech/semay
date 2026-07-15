import { NextResponse } from "next/server";
import { adminAuth } from "@/lib/firebaseAdmin";

const SESSION_EXPIRES_IN_MS = 5 * 24 * 60 * 60 * 1000;

export async function POST(request: Request) {
  const { idToken } = await request.json();
  if (!idToken || typeof idToken !== "string") {
    return NextResponse.json({ error: "idToken is required" }, { status: 400 });
  }

  let decoded;
  try {
    decoded = await adminAuth.verifyIdToken(idToken);
  } catch {
    return NextResponse.json({ error: "invalid idToken" }, { status: 401 });
  }

  if (decoded.role !== "superadmin") {
    return NextResponse.json({ error: "forbidden" }, { status: 403 });
  }

  const sessionCookie = await adminAuth.createSessionCookie(idToken, {
    expiresIn: SESSION_EXPIRES_IN_MS,
  });

  const res = NextResponse.json({ success: true });
  res.cookies.set("session", sessionCookie, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    maxAge: SESSION_EXPIRES_IN_MS / 1000,
    path: "/",
  });
  return res;
}
