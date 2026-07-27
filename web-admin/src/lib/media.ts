import "server-only";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

// Writes directly into the SAME local media folder server/ serves (no MinIO).
// server/ and web-admin/ run on the same box, so they share MEDIA_DIR; the file
// is then served by server/'s /media static mount at MEDIA_PUBLIC_BASE_URL.
// MEDIA_DIR defaults to server/'s ./media relative to the web-admin cwd.
const MEDIA_DIR = path.resolve(process.env.MEDIA_DIR ?? "../server/media");
export const MEDIA_PUBLIC_BASE_URL = process.env.MEDIA_PUBLIC_BASE_URL!;

/** Writes `bytes` to `<MEDIA_DIR>/<key>` (creating parent dirs). Key comes only
 * from server code here (never user input), but resolve-and-check anyway so a
 * stray `..` can't escape the media root. */
export async function writeMediaObject(key: string, bytes: Buffer): Promise<void> {
  const dest = path.resolve(MEDIA_DIR, key);
  const root = MEDIA_DIR.endsWith(path.sep) ? MEDIA_DIR : MEDIA_DIR + path.sep;
  if (!dest.startsWith(root)) throw new Error("invalid media key");
  await mkdir(path.dirname(dest), { recursive: true });
  await writeFile(dest, bytes);
}
