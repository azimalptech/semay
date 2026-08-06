import { randomUUID } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdir, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

import type { FastifyInstance } from "fastify";
import { z } from "zod";

import { requireAuth, requireFreshAuth } from "../auth/middleware.js";
import { requireRole } from "../auth/authz.js";
import { config } from "../config.js";
import { pathForKey, publicUrlForKey, signUpload, verifyUpload } from "./storage.js";

// Strict allowlist, NOT a character-class regex. Uploaded files are served
// publicly from the API's own origin, so an admin who could store `x.html`,
// `x.svg` or `x.js` there would get script execution on that origin — stored XSS
// against every user, including the superadmin panel's session cookies. Only
// formats the app actually renders are permitted, and `svg` is deliberately
// excluded (it is an XML document that can carry <script>, not an inert image).
const ALLOWED_FILE_EXTS = ["jpg", "jpeg", "png", "webp", "heic", "mp4", "mov", "webm"] as const;

const uploadUrlSchema = z.object({
  fileExt: z
    .string()
    .toLowerCase()
    .pipe(z.enum(ALLOWED_FILE_EXTS)),
  folder: z.enum(["posts", "stores", "stories", "chats"]),
});

// The mobile client streams the raw file bytes to the PUT below (Content-Type
// image/jpeg | video/mp4 | …). Fastify would otherwise reject an unparsed body
// type with 415, so pass the raw request stream straight through as the body.
// Scoped to this plugin — the JSON parser is still inherited for /upload-url.
const MAX_UPLOAD_BYTES = 120 * 1024 * 1024; // videos are capped at 100MB client-side

export async function mediaRoutes(app: FastifyInstance): Promise<void> {
  app.addContentTypeParser("*", (_req, payload, done) => done(null, payload));

  // Origin the uploads are PUT to = origin media is served from (the API serves
  // /media itself). Derived once from MEDIA_PUBLIC_BASE_URL.
  const apiOrigin = new URL(config.MEDIA_PUBLIC_BASE_URL).origin;

  // Any admin (store or super) may request an upload slot — per-store scoping is
  // enforced when the resulting URL is actually attached to a post/store/story.
  app.post(
    "/media/upload-url",
    { preHandler: [requireAuth, requireFreshAuth, requireRole("admin", "superadmin")] },
    async (req, reply) => {
      const body = uploadUrlSchema.safeParse(req.body);
      if (!body.success) return reply.code(400).send({ error: "INVALID_INPUT" });

      const key = `${body.data.folder}/${randomUUID()}.${body.data.fileExt}`;
      const { exp, sig } = signUpload(key);
      const uploadUrl = `${apiOrigin}/api/v1/media/blob/${key}?exp=${exp}&sig=${sig}`;

      return reply.send({ uploadUrl, publicUrl: publicUrlForKey(key), expiresInSeconds: 300 });
    }
  );

  // Unauthenticated but signature-gated: the mobile client PUTs bytes here with
  // no bearer token (matches the old presigned-URL flow). The signature over
  // (key, exp) is what authorizes it, so only a server-issued slot can write.
  app.put("/media/blob/*", async (req, reply) => {
    const key = (req.params as Record<string, string>)["*"];
    const { exp, sig } = req.query as { exp?: string; sig?: string };
    if (!key || !sig || !verifyUpload(key, Number(exp), sig)) {
      return reply.code(403).send({ error: "INVALID_OR_EXPIRED_UPLOAD_URL" });
    }

    const contentLength = Number(req.headers["content-length"]);
    if (Number.isFinite(contentLength) && contentLength > MAX_UPLOAD_BYTES) {
      return reply.code(413).send({ error: "FILE_TOO_LARGE" });
    }

    let dest: string;
    try {
      dest = pathForKey(key);
    } catch {
      return reply.code(400).send({ error: "INVALID_KEY" });
    }
    await mkdir(path.dirname(dest), { recursive: true });

    // Real uploads (image/*, video/*) arrive as a stream via the `*` parser
    // above. Guard the odd case where a content-type with a built-in buffering
    // parser (json/text) slipped through, so it writes instead of 500-ing.
    const body = req.body as unknown;
    if (Buffer.isBuffer(body) || typeof body === "string") {
      if (Buffer.byteLength(body) > MAX_UPLOAD_BYTES) {
        return reply.code(413).send({ error: "FILE_TOO_LARGE" });
      }
      await writeFile(dest, body);
      return reply.send({ ok: true });
    }

    const source = body as NodeJS.ReadableStream;
    const out = createWriteStream(dest);
    let written = 0;
    try {
      await new Promise<void>((resolve, reject) => {
        source.on("data", (chunk: Buffer) => {
          written += chunk.length;
          if (written > MAX_UPLOAD_BYTES) {
            reject(new Error("FILE_TOO_LARGE"));
            return;
          }
          if (!out.write(chunk)) {
            source.pause();
            out.once("drain", () => source.resume());
          }
        });
        source.on("end", () => out.end(resolve));
        source.on("error", reject);
        out.on("error", reject);
      });
    } catch (err) {
      out.destroy();
      await unlink(dest).catch(() => {});
      if ((err as Error).message === "FILE_TOO_LARGE") {
        return reply.code(413).send({ error: "FILE_TOO_LARGE" });
      }
      throw err;
    }

    return reply.send({ ok: true });
  });
}
