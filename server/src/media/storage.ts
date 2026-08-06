import { createHmac, timingSafeEqual } from "node:crypto";
import { mkdir, readdir, unlink } from "node:fs/promises";
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

/** The storage key for a public media URL this server issued, or undefined if the
 * URL points somewhere else (an externally hosted image, a stale URL from an
 * older MEDIA_PUBLIC_BASE_URL, or anything a client made up). */
export function keyForPublicUrl(url: string): string | undefined {
  const base = config.MEDIA_PUBLIC_BASE_URL.replace(/\/+$/, "");
  if (!url.startsWith(`${base}/`)) return undefined;
  const key = url.slice(base.length + 1);
  // Reject anything that isn't a plain `folder/name.ext` key before it reaches
  // pathForKey — no traversal, no absolute paths, no query strings.
  if (!/^[a-z]+\/[A-Za-z0-9._-]+$/.test(key)) return undefined;
  return key;
}

/** Best-effort delete of stored media by public URL.
 *
 * Deliberately never throws: media files are derived data, and failing a post
 * deletion (whose DB rows are already gone) because a file was already missing
 * would be strictly worse than leaving a stray byte range on disk. Returns
 * whether a file was actually removed, for logging. */
export async function deleteMediaByUrl(url: string | null | undefined): Promise<boolean> {
  if (!url) return false;
  const key = keyForPublicUrl(url);
  if (!key) return false;
  try {
    await unlink(pathForKey(key));
    return true;
  } catch {
    return false; // already gone, outside MEDIA_DIR, or unreadable
  }
}

/** Every file currently under MEDIA_DIR, as absolute paths. Used by the
 * maintenance reaper to find files the database no longer references. */
export async function listMediaFiles(): Promise<string[]> {
  const out: string[] = [];
  async function walk(dir: string): Promise<void> {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return; // directory vanished mid-walk
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) await walk(full);
      else if (entry.isFile()) out.push(full);
    }
  }
  await walk(MEDIA_DIR);
  return out;
}

export async function deleteMediaByUrls(urls: (string | null | undefined)[]): Promise<number> {
  const results = await Promise.all(urls.map((u) => deleteMediaByUrl(u)));
  return results.filter(Boolean).length;
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
