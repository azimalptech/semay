import { Prisma, type Chat, type Language, type Order } from "@prisma/client";

import { sendMessage } from "../chats/service.js";
import { prisma } from "../db.js";
import { copyFor } from "../lib/copy.js";
import { withRetry } from "../lib/withRetry.js";
import { sendLocalizedPushToUsers } from "../notifications/push.js";

/** Android notification channel for order notices — created at IMPORTANCE_HIGH
 * with the system default sound by the app's SemayApplication.kt. Named rather
 * left to the manifest default, because that default is the chat channel and an
 * order notice would otherwise be filed under Messages — where a user muting
 * chat would silence it too (docs/08 §3b). */
const ORDER_PUSH_CHANNEL = "orders";

/** Posts the order's system message into the chat, exactly once.
 *
 * Reuses sendMessage so the chat's last-message/unread fields and every realtime
 * publish stay in sync the same way a normal message would. The clientKey is
 * derived from the order id rather than random, which is what makes this safe to
 * call again on a retried accept: the second call dedupes against the first
 * inside sendMessage instead of posting the confirmation twice.
 *
 * The text is written in the CUSTOMER's language: it is one persisted row that
 * both sides read, so it cannot follow the reader, and of the two it is the
 * customer the message informs — the admin is only reading back the tap they
 * just made. Wording matches the app's own `l10n.dart` orderAccepted, and it
 * doubles as the chat push's body (sendMessage → sendChatPush), which is why an
 * English literal here would have reached a Turkmen/Russian-only product's
 * notification shade. */
async function ensureOrderMessage(
  chat: Chat,
  adminId: string,
  order: Order,
  customerLanguage: Language
): Promise<void> {
  await sendMessage(chat, "admin", adminId, {
    text: copyFor(customerLanguage).orderAccepted,
    orderId: order.id,
    clientKey: `order:${order.id}`,
  });
}

/** The tap itself is the completed sale — there is no pending/approval status,
 * `status` only ever holds `'accepted'` (matches the old callable's contract:
 * no updateOrderStatus, no Super Admin approval step). */
export async function acceptOrder(
  chat: Chat,
  adminId: string,
  itemQuantity: number,
  clientKey?: string
): Promise<Order> {
  const customer = await prisma.user.findUniqueOrThrow({
    where: { id: chat.userId },
    select: { phone: true, name: true, language: true },
  });

  // Idempotency fast-path, mirroring sendMessage: a retried accept (lost
  // response on a flaky network) must return the original sale rather than
  // recording a second one and double-incrementing the prize leaderboard.
  if (clientKey) {
    const existing = await prisma.order.findUnique({ where: { clientKey } });
    if (existing) {
      // Deliberately still runs: if the very first attempt died between
      // creating the order and posting its chat message, this retry is what
      // finally posts it. sendMessage's own clientKey dedup makes it a no-op
      // when the message already exists.
      await ensureOrderMessage(chat, adminId, existing, customer.language);
      return existing;
    }
  }

  let order: Order;
  try {
    order = await withRetry(() =>
    prisma.$transaction(async (tx) => {
      const order = await tx.order.create({
        data: {
          storeId: chat.storeId,
          adminId,
          userId: chat.userId,
          chatId: chat.id,
          itemQuantity,
          userPhone: customer.phone,
          clientKey,
        },
      });

      // The order is always recorded (it's a real sale for the orders report),
      // but it only moves the leaderboard while the store's campaign window is
      // open: on/after campaignStartAt and on/before campaignEndAt. A NULL bound
      // means that side is open-ended. So after the end date passes, new orders
      // stop counting and the standings freeze at their final campaign values;
      // an order before the start (or with no campaign at all — both NULL) still
      // counts, preserving the prior "always counts" behavior when unset.
      const store = await tx.store.findUniqueOrThrow({
        where: { id: chat.storeId },
        select: { campaignStartAt: true, campaignEndAt: true },
      });
      const now = new Date();
      const started = !store.campaignStartAt || store.campaignStartAt <= now;
      const notEnded = !store.campaignEndAt || now <= store.campaignEndAt;
      if (started && notEnded) {
        await tx.storeLeaderboard.upsert({
          where: { storeId_userId: { storeId: chat.storeId, userId: chat.userId } },
          create: {
            storeId: chat.storeId,
            userId: chat.userId,
            userName: customer.name,
            quantity: itemQuantity,
          },
          update: { quantity: { increment: itemQuantity }, userName: customer.name },
        });
      }
      return order;
    })
    );
  } catch (err) {
    // Two simultaneous accepts carrying the same key raced past the fast-path
    // check above; the loser returns the winner's order rather than erroring.
    if (
      clientKey &&
      err instanceof Prisma.PrismaClientKnownRequestError &&
      err.code === "P2002"
    ) {
      const winner = await prisma.order.findUnique({ where: { clientKey } });
      if (winner) {
        await ensureOrderMessage(chat, adminId, winner, customer.language);
        return winner;
      }
    }
    throw err;
  }

  await ensureOrderMessage(chat, adminId, order, customer.language);

  const superadmins = await prisma.user.findMany({
    where: { role: "superadmin" },
    select: { id: true },
  });
  // Localized per superadmin (lib/copy.ts): the whole notice is server-written
  // copy, and the product has no English.
  await sendLocalizedPushToUsers(
    superadmins.map((s) => s.id),
    (copy) => ({
      title: copy.newOrder,
      body: copy.orderPlaced(customer.name || customer.phone, itemQuantity),
    }),
    undefined,
    { channelId: ORDER_PUSH_CHANNEL }
  );

  return order;
}
