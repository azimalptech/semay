import type { FastifyInstance } from "fastify";
import { Prisma } from "@prisma/client";
import { z } from "zod";

import { config } from "../config.js";
import { prisma } from "../db.js";
import { getClaimsForUser } from "./claims.js";
import { signAccessToken } from "../lib/jwt.js";
import { requireAuth } from "./middleware.js";
import {
  clearOtp,
  OtpCooldownError,
  OtpInvalidError,
  OtpLockedError,
  requestOtp,
  verifyOtp,
} from "./otpStore.js";
import { smsProvider } from "./sms.js";
import { createSession, findActiveSession, revokeSession, rotateSession, SessionInvalidError } from "./session.js";
import { findOrCreateUserByPhone } from "./users.js";

const phoneSchema = z.string().regex(/^\+?[1-9]\d{6,14}$/, "Invalid phone number");

const sendSchema = z.object({ phone: phoneSchema });
const verifySchema = z.object({
  phone: phoneSchema,
  code: z.string().regex(/^\d{6}$/),
  deviceInfo: z.string().max(255).optional(),
});
const refreshSchema = z.object({ refreshToken: z.string().min(1) });
const logoutSchema = z.object({ refreshToken: z.string().min(1) });
const changePhoneSchema = z.object({ phone: phoneSchema, code: z.string().regex(/^\d{6}$/) });

export async function authRoutes(app: FastifyInstance): Promise<void> {
  app.post("/auth/otp/send", async (req, reply) => {
    const body = sendSchema.safeParse(req.body);
    if (!body.success) {
      return reply.code(400).send({ error: "INVALID_PHONE" });
    }
    const { phone } = body.data;

    try {
      const { code } = await requestOtp(phone);
      try {
        await smsProvider.send(phone, `SeMay code: ${code}`);
      } catch (sendErr) {
        // The code row was written (starting the resend cooldown) but the SMS
        // never left — clear it so the user can retry immediately instead of
        // being stuck in cooldown for a code they never got.
        await clearOtp(phone).catch(() => {});
        req.log.error({ err: sendErr, phone }, "OTP SMS send failed");
        return reply.code(502).send({ error: "OTP_SEND_FAILED" });
      }
      return reply.send({
        ok: true,
        ...(config.OTP_DEV_MODE ? { devCode: code } : {}),
      });
    } catch (err) {
      if (err instanceof OtpCooldownError) {
        return reply
          .code(429)
          .send({ error: "OTP_COOLDOWN", retryAfterSeconds: err.retryAfterSeconds });
      }
      if (err instanceof OtpLockedError) {
        return reply
          .code(429)
          .send({ error: "OTP_LOCKED", lockedUntil: err.lockedUntil.toISOString() });
      }
      throw err;
    }
  });

  app.post("/auth/otp/verify", async (req, reply) => {
    const body = verifySchema.safeParse(req.body);
    if (!body.success) {
      return reply.code(400).send({ error: "INVALID_INPUT" });
    }
    const { phone, code, deviceInfo } = body.data;

    try {
      await verifyOtp(phone, code);
    } catch (err) {
      if (err instanceof OtpLockedError) {
        return reply
          .code(429)
          .send({ error: "OTP_LOCKED", lockedUntil: err.lockedUntil.toISOString() });
      }
      if (err instanceof OtpInvalidError) {
        return reply
          .code(401)
          .send({ error: "OTP_INVALID", attemptsRemaining: err.attemptsRemaining });
      }
      throw err;
    }

    const user = await findOrCreateUserByPhone(phone);
    const claims = await getClaimsForUser(user.id);
    const accessToken = signAccessToken(claims);
    const { refreshToken } = await createSession(user.id, deviceInfo);

    return reply.send({
      accessToken,
      refreshToken,
      user: {
        id: user.id,
        phone: user.phone,
        name: user.name,
        avatarUrl: user.avatarUrl,
        role: user.role,
        language: user.language,
        darkMode: user.darkMode,
      },
    });
  });

  app.post("/auth/refresh", async (req, reply) => {
    const body = refreshSchema.safeParse(req.body);
    if (!body.success) {
      return reply.code(400).send({ error: "INVALID_INPUT" });
    }

    try {
      const oldSession = await findActiveSession(body.data.refreshToken);
      const { session, refreshToken } = await rotateSession(oldSession);
      const claims = await getClaimsForUser(session.userId);
      const accessToken = signAccessToken(claims);
      return reply.send({ accessToken, refreshToken });
    } catch (err) {
      if (err instanceof SessionInvalidError) {
        return reply.code(401).send({ error: "SESSION_INVALID" });
      }
      throw err;
    }
  });

  app.post("/auth/logout", async (req, reply) => {
    const body = logoutSchema.safeParse(req.body);
    if (!body.success) {
      return reply.code(400).send({ error: "INVALID_INPUT" });
    }

    try {
      const session = await findActiveSession(body.data.refreshToken);
      await revokeSession(session.id);
    } catch (err) {
      if (!(err instanceof SessionInvalidError)) throw err;
      // Already invalid/expired/revoked — logout is idempotent either way.
    }
    return reply.send({ ok: true });
  });

  // Re-verifies ownership of a *new* phone number (same /auth/otp/send code
  // the client requests for it first, then this) before repointing the
  // caller's own phone at it — phone is the OTP login identity, so it can't
  // be changed by a plain PATCH /users/me the way name/avatarUrl can.
  app.post("/auth/change-phone", { preHandler: requireAuth }, async (req, reply) => {
    const body = changePhoneSchema.safeParse(req.body);
    if (!body.success) {
      return reply.code(400).send({ error: "INVALID_INPUT" });
    }
    const { phone, code } = body.data;

    try {
      await verifyOtp(phone, code);
    } catch (err) {
      if (err instanceof OtpLockedError) {
        return reply
          .code(429)
          .send({ error: "OTP_LOCKED", lockedUntil: err.lockedUntil.toISOString() });
      }
      if (err instanceof OtpInvalidError) {
        return reply
          .code(401)
          .send({ error: "OTP_INVALID", attemptsRemaining: err.attemptsRemaining });
      }
      throw err;
    }

    try {
      const user = await prisma.user.update({ where: { id: req.auth!.sub }, data: { phone } });
      return reply.send({ user: { id: user.id, phone: user.phone } });
    } catch (err) {
      if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === "P2002") {
        return reply.code(409).send({ error: "PHONE_ALREADY_IN_USE" });
      }
      throw err;
    }
  });
}
