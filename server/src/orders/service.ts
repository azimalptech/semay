import type { Chat, Order } from "@prisma/client";

import { sendMessage } from "../chats/service.js";
import { prisma } from "../db.js";
import { withRetry } from "../lib/withRetry.js";
import { sendPushToUsers } from "../notifications/push.js";

/** The tap itself is the completed sale — there is no pending/approval status,
 * `status` only ever holds `'accepted'` (matches the old callable's contract:
 * no updateOrderStatus, no Super Admin approval step). */
export async function acceptOrder(chat: Chat, adminId: string, itemQuantity: number): Promise<Order> {
  const customer = await prisma.user.findUniqueOrThrow({
    where: { id: chat.userId },
    select: { phone: true, name: true },
  });

  const order = await withRetry(() =>
    prisma.$transaction(async (tx) => {
      const order = await tx.order.create({
        data: {
          storeId: chat.storeId,
          adminId,
          userId: chat.userId,
          chatId: chat.id,
          itemQuantity,
          userPhone: customer.phone,
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

  // System message referencing the order — reuses sendMessage so the chat's
  // last-message/unread fields and every realtime publish (chat, chat
  // messages, both list channels) stay in sync the same way a normal message
  // would, instead of duplicating that logic here.
  await sendMessage(chat, "admin", adminId, { text: "Order accepted ✅", orderId: order.id });

  const superadmins = await prisma.user.findMany({
    where: { role: "superadmin" },
    select: { id: true },
  });
  await sendPushToUsers(
    superadmins.map((s) => s.id),
    "New order",
    `${customer.name || customer.phone} placed an order (${itemQuantity})`
  );

  return order;
}
