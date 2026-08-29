// Creates audit fixtures against the running server and prints tokens.
import { PrismaClient } from "@prisma/client";

const B = "http://127.0.0.1:8096/api/v1";
const prisma = new PrismaClient();

const AUDIT_PREFIX = "+99319"; // synthetic range, distinct from any real data

async function post(path, body, token) {
  const res = await fetch(B + path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

/** Signs an account in via the dev-mode OTP flow. */
async function login(phone, name) {
  const send = await post("/auth/otp/send", { phone });
  const code = send.body.devCode;
  if (!code) throw new Error(`no devCode for ${phone}: ${JSON.stringify(send)}`);
  const v = await post("/auth/otp/verify", { phone, code, name });
  if (!v.body.accessToken) throw new Error(`verify failed for ${phone}: ${JSON.stringify(v)}`);
  return v.body;
}

const created = { users: [], stores: [] };

try {
  // Three roles, so authorization can actually be exercised from each side.
  const userA = await login(`${AUDIT_PREFIX}000001`, "Audit User A");
  const userB = await login(`${AUDIT_PREFIX}000002`, "Audit User B");
  const adminU = await login(`${AUDIT_PREFIX}000003`, "Audit Store Admin");
  const superU = await login(`${AUDIT_PREFIX}000004`, "Audit Superadmin");
  created.users.push(userA.user.id, userB.user.id, adminU.user.id, superU.user.id);

  await prisma.user.update({
    where: { id: superU.user.id },
    data: { role: "superadmin", claimsVersion: { increment: 1 } },
  });

  const store = await prisma.store.create({
    data: { name: "Audit Store", phone: `${AUDIT_PREFIX}000009`, createdById: superU.user.id },
  });
  created.stores.push(store.id);

  await prisma.storeAdmin.create({ data: { storeId: store.id, userId: adminU.user.id } });
  await prisma.user.update({
    where: { id: adminU.user.id },
    data: { role: "admin", claimsVersion: { increment: 1 } },
  });

  // Re-login the two whose claims changed, so their tokens carry the new role.
  const adminFresh = await login(`${AUDIT_PREFIX}000003`);
  const superFresh = await login(`${AUDIT_PREFIX}000004`);

  const out = {
    base: B,
    storeId: store.id,
    user: { id: userA.user.id, phone: userA.user.phone, token: userA.accessToken, refresh: userA.refreshToken },
    user2: { id: userB.user.id, phone: userB.user.phone, token: userB.accessToken },
    storeAdmin: { id: adminU.user.id, phone: adminU.user.phone, token: adminFresh.accessToken },
    superadmin: { id: superU.user.id, phone: superU.user.phone, token: superFresh.accessToken },
    auditPrefix: AUDIT_PREFIX,
  };
  console.log(JSON.stringify(out, null, 2));
} finally {
  await prisma.$disconnect();
}
