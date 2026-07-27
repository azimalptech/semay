import { createHmac, timingSafeEqual } from "node:crypto";
import { mkdir } from "node:fs/promises";
import path from "node:path";

import { config } from "../config.js";

// Local public media folder — replaces MinIO. Uploaded post/story/store/chat
// media is written here as plain files and served back statically (see app.ts's
// @fastify/static mount at /media) at MEDIA_PUBLIC_BASE_URL. Keys are
// `folder/uuid.ext`, so the on-disk layout mirrors the public URL path exactly.
export const MEDIA_DIR = path.resolve(config.MEDIA_DIR);

/** Absolute on-disk path for a media key, with a hard traversal guard: the
 * resolved path must stay inside MEDIA_DIR (a `../` in a tampered key can never
 * escape it). */
export function pathForKey(key: string): string {
  const abs = path.resolve(MEDIA_DIR, key);
  const root = MEDIA_DIR.endsWith(path.sep) ? MEDIA_DIR : MEDIA_DIR + path.sep;
  if (abs !== MEDIA_DIR && !abs.startsWith(root)) {
    throw new Error("INVALID_KEY");
  }
  return abs;
}

/** Public URL a client fetches this key at. */
export function publicUrlForKey(key: string): string {
  return `${config.MEDIA_PUBLIC_BASE_URL}/${key}`;
}

const UPLOAD_TTL_MS = 5 * 60 * 1000;

function sign(key: string, exp: number): string {
  return createHmac("sha256", config.JWT_SECRET).update(`${key}:${exp}`).digest("hex");
}

/** A short-lived signature authorizing an unauthenticated PUT of `key`
 * (mirrors the old presigned-URL model — the mobile client PUTs the bytes
 * directly with no bearer token). */
export function signUpload(key: string): { exp: number; sig: string } {
  const exp = Date.now() + UPLOAD_TTL_MS;
  return { exp, sig: sign(key, exp) };
}

export function verifyUpload(key: string, exp: number, sig: string): boolean {
  if (!Number.isFinite(exp) || Date.now() > exp) return false;
  const expected = sign(key, exp);
  const a = Buffer.from(expected);
  const b = Buffer.from(sig);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Idempotent — creates the media folder at boot so the first upload doesn't
 * race a missing directory. Replaces MinIO's ensureMediaBucket. */
export async function ensureMediaDir(): Promise<void> {
  await mkdir(MEDIA_DIR, { recursive: true });
}
