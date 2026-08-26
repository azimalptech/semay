import type { FastifyInstance } from "fastify";
import { Prisma } from "@prisma/client";
import { z } from "zod";

import { config } from "../config.js";
import { prisma } from "../db.js";
import { getClaimsForUser } from "./claims.js";
import { signAccessToken } from "../lib/jwt.js";
import { requireRole } from "./authz.js";
import { requireAuth, requireFreshAuth } from "./middleware.js";
import {
  clearOtp,
  isTestPhone,
  OtpCooldownError,
  NameRequiredError,
  OtpInvalidError,
  OtpLockedError,
  requestOtp,
  TestPhonePrivilegedError,
  verifyOtp,
} from "./otpStore.js";
import { smsProvider } from "./sms.js";
import { createSession, findActiveSession, revokeSession, rotateSession, SessionInvalidError } from "./session.js";
import { hashPassword, verifyPassword } from "./superadminAuth.js";

const phoneSchema = z.string().regex(/^\+?[1-9]\d{6,14}$/, "Invalid phone number");

const sendSchema = z.object({ phone: phoneSchema });
const verifySchema = z.object({
  phone: phoneSchema,
  code: z.string().regex(/^\d{6}$/),
  // Required only when this phone has no account yet — the server answers
  // NAME_REQUIRED (without consuming the code) so the client can collect one
  // and retry. Ignored for an existing account, so returning users are never
  // asked again.
  name: z.string().trim().min(1).max(120).optional(),
  deviceInfo: z.string().max(255).optional(),
});
const refreshSchema = z.object({ refreshToken: z.string().min(1) });
const logoutSchema = z.object({ refreshToken: z.string().min(1) });
const changePhoneSchema = z.object({ phone: phoneSchema, code: z.string().regex(/^\d{6}$/) });
const superadminLoginSchema = z.object({
  phone: phoneSchema,
  password: z.string().min(1).max(255),
  deviceInfo: z.string().max(255).optional(),
});
// 12 chars minimum: this single password guards broadcast-to-every-user, store
// creation/deletion and cross-store order visibility, and it is the one
// brute-forceable surface in a system where everything else needs possession of
// a phone. The seeded value was 10 characters and a dictionary word.
const changePasswordSchema = z.object({
  currentPassword: z.string().min(1).max(255),
  newPassword: z.string().min(12).max(255),
});

// Tighter per-IP cap for the unauthenticated auth surface. The global limit is
// deliberately generous (carrier NAT puts many real users behind one IP), but
// that generosity is wrong here: the per-phone cooldown/lockout in otpStore only
// bounds abuse of a SINGLE number, so one IP could still pump OTP SMS to
// thousands of DIFFERENT numbers — real money out of the SMS gateway, and a
// phone-number enumeration oracle. RATE_LIMIT_AUTH_MAX_PER_MIN existed in the
// config and .env.example for exactly this and was never actually wired up.
//
// Skipped under test, matching app.ts (the global limiter isn't registered there,
// and route-level config would have nothing to attach to).
const authRateLimit =
  process.env.NODE_ENV === "test"
    ? {}
    : {
        config: {
          rateLimit: { max: config.RATE_LIMIT_AUTH_MAX_PER_MIN, timeWindow: "1 minute" },
        },
      };

export async function authRoutes(app: FastifyInstance): Promise<void> {
  app.post("/auth/otp/send", authRateLimit, async (req, reply) => {
    const body = sendSchema.safeParse(req.body);
    if (!body.success) {
      return reply.code(400).send({ error: "INVALID_PHONE" });
    }
    const { phone } = body.data;

    // The demo account's code is fixed, so there is nothing to generate and
    // nothing to send. Returning early also keeps it out of the per-phone
    // resend cooldown, which would otherwise lock a reviewer out for a minute
    // after their first tap, and avoids paying for an SMS nobody reads.
    if (isTestPhone(phone)) {
      return reply.send({ ok: true });
    }

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

  app.post("/auth/otp/verify", authRateLimit, async (req, reply) => {
    const body = verifySchema.safeParse(req.body);
    if (!body.success) {
      return reply.code(400).send({ error: "INVALID_INPUT" });
    }
    const { phone, code, name, deviceInfo } = body.data;

    let user;
    try {
      // Account creation happens inside verifyOtp's transaction, so a row can
      // never exist without a name — see NameRequiredError there.
      user = await verifyOtp(phone, code, name);
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
      if (err instanceof NameRequiredError) {
        // The code was correct and is still valid — the client collects a name
        // and retries this same call with it.
        return reply.code(400).send({ error: "NAME_REQUIRED" });
      }
      if (err instanceof TestPhonePrivilegedError) {
        // Someone promoted the demo account. Refuse and make it loud: this is a
        // misconfiguration that would otherwise hand a published, permanent
        // credential real privileges, and the only external symptom would be a
        // demo login that quietly did more than it should.
        req.log.error(
          { phone, role: err.role },
          "OTP_TEST_PHONE points at a privileged account — demo login refused"
        );
        return reply.code(403).send({ error: "TEST_PHONE_NOT_PERMITTED" });
      }
      throw err;
    }

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

  // Password login for the Super Admin web panel only — see superadminAuth.ts
  // for why this exists alongside (not instead of) the OTP flow above, which
  // every other account still uses. Rate-limited the same as the OTP routes:
  // this is now the one password-guessable surface in the system, and it
  // guards the single most privileged role, so it needs it more, not less.
  app.post("/auth/superadmin/login", authRateLimit, async (req, reply) => {
    const body = superadminLoginSchema.safeParse(req.body);
    if (!body.success) {
      return reply.code(400).send({ error: "INVALID_INPUT" });
    }
    const { phone, password, deviceInfo } = body.data;

    // Generic failure for every rejection reason (unknown phone, wrong
    // password, a real account that just isn't superadmin, no password set
    // yet) — a differentiated error would let an attacker enumerate which
    // phone numbers exist or hold the superadmin role.
    const user = await prisma.user.findUnique({ where: { phone } });
    const passwordOk = await verifyPassword(password, user?.passwordHash ?? null);
    if (!user || user.role !== "superadmin" || !passwordOk) {
      return reply.code(401).send({ error: "INVALID_CREDENTIALS" });
    }

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

  // Self-service password change for the superadmin panel. Until now the only
  // way to change it was a direct UPDATE against the database, which meant in
  // practice it never got changed — the account was still on its seeded value.
  //
  // requireFreshAuth so a token minted before a demotion can't be replayed
  // here, and the CURRENT password is required even though the caller is
  // already authenticated: an access token left behind on an unlocked machine
  // shouldn't be enough to lock the real owner out.
  app.post(
    "/auth/superadmin/change-password",
    { preHandler: [requireAuth, requireFreshAuth, requireRole("superadmin")], ...authRateLimit },
    async (req, reply) => {
      const body = changePasswordSchema.safeParse(req.body);
      if (!body.success) {
        // Surfaces the length rule rather than a bare INVALID_INPUT, since
        // that's the only way the caller can act on the rejection.
        return reply
          .code(400)
          .send({ error: "INVALID_INPUT", message: "New password must be at least 12 characters" });
      }

      const user = await prisma.user.findUniqueOrThrow({ where: { id: req.auth!.sub } });
      if (!(await verifyPassword(body.data.currentPassword, user.passwordHash))) {
        return reply.code(401).send({ error: "INVALID_CREDENTIALS" });
      }

      await prisma.user.update({
        where: { id: user.id },
        data: { passwordHash: await hashPassword(body.data.newPassword) },
      });

      // Every existing session dies, this one included. A password change is
      // the standard response to "someone may have my credentials", so leaving
      // other logins alive would defeat the point; the caller simply signs in
      // again with the new password.
      await prisma.session.deleteMany({ where: { userId: user.id } });

      return reply.send({ ok: true });
    }
  );

  app.post("/auth/refresh", authRateLimit, async (req, reply) => {
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
