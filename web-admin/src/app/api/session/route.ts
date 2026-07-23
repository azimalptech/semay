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
  // Deliberately NOT named "__session": that exact name is reserved by
  // Firebase Hosting's own Next.js SSR integration for its built-in
  // "Authenticated Experience" auto-auth feature, which tries to reinterpret
  // any __session cookie as a raw ID token and call signInWithCustomToken
  // with it server-side. Our cookie is a *session* cookie (different
  // lifecycle/format from an ID token), so that misfired and crashed SSR
  // rendering ("Firebase App ... already deleted") — the exact 500s that
  // broke /stores and /broadcast. Firebase Hosting's CDN also only passes
  // through a cookie named exactly __session, which is why this app is
  // reached via the direct Cloud Run URL instead of semay-b57ee.web.app —
  // both constraints point at __session, and neither can be satisfied at
  // the same time on this integration.
  res.cookies.set("session", sessionCookie, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    maxAge: SESSION_EXPIRES_IN_MS / 1000,
    path: "/",
  });
  return res;
}
