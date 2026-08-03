import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { prisma } from "../src/db.js";
import { createOrGetChat, sendMessage } from "../src/chats/service.js";

// Regression: sendMessage looked the quoted message up by id ALONE, then copied
// its text onto the new message and returned it to the sender. Because message
// ids are sequential BIGINTs, any authenticated user could sit in their own chat
// and walk id=1,2,3… to read the first 512 characters of every private message
// in the database — every other customer's conversation with every store.
// The lookup is now scoped to the sending chat.
describe("reply-to cannot read messages from another chat", () => {
  let victimUserId: string;
  let attackerUserId: string;
  let storeId: string;
  let secretMessageId: bigint;

  const SECRET = "my card number is 1234-5678-9012-3456";

  beforeAll(async () => {
    const mkPhone = () => `+9937${Math.floor(1_000_000 + Math.random() * 8_999_999)}`;
    const victim = await prisma.user.create({ data: { phone: mkPhone() } });
    const attacker = await prisma.user.create({ data: { phone: mkPhone() } });
    victimUserId = victim.id;
    attackerUserId = attacker.id;

    const store = await prisma.store.create({
      data: { name: "IDOR Test Store", createdById: victim.id },
    });
    storeId = store.id;

    // Victim's private conversation with the store.
    const victimChat = await createOrGetChat(victimUserId, storeId);
    const secret = await sendMessage(victimChat, "user", victimUserId, { text: SECRET });
    secretMessageId = secret.id;
  });

  afterAll(async () => {
    await prisma.store.delete({ where: { id: storeId } }); // cascades chats/messages
    await prisma.user.deleteMany({ where: { id: { in: [victimUserId, attackerUserId] } } });
  });

  it("does not copy another chat's message text into the reply quote", async () => {
    // The attacker has their own, entirely separate chat with the same store.
    const attackerChat = await createOrGetChat(attackerUserId, storeId);

    const sent = await sendMessage(attackerChat, "user", attackerUserId, {
      text: "nice try",
      replyToMessageId: secretMessageId.toString(),
    });

    // The message still sends — but carries none of the victim's content.
    expect(sent.replyToText).toBeNull();
    expect(sent.replyToSenderRole).toBeNull();
    // ...and does not even retain a pointer into the victim's chat.
    expect(sent.replyToMessageId).toBeNull();

    // Belt and braces: the secret must appear nowhere on the attacker's row.
    expect(JSON.stringify(sent)).not.toContain("1234-5678-9012-3456");
  });

  it("still quotes correctly when replying within the same chat", async () => {
    const victimChat = await createOrGetChat(victimUserId, storeId);

    const reply = await sendMessage(victimChat, "admin", victimUserId, {
      text: "replying to my own chat",
      replyToMessageId: secretMessageId.toString(),
    });

    expect(reply.replyToMessageId).toBe(secretMessageId);
    expect(reply.replyToText).toBe(SECRET);
    expect(reply.replyToSenderRole).toBe("user");
  });

  it("ignores a wholly nonexistent id instead of failing the send", async () => {
    const attackerChat = await createOrGetChat(attackerUserId, storeId);

    const sent = await sendMessage(attackerChat, "user", attackerUserId, {
      text: "reply to a deleted message",
      replyToMessageId: "999999999",
    });

    expect(sent.replyToText).toBeNull();
    expect(sent.replyToMessageId).toBeNull();
    expect(sent.text).toBe("reply to a deleted message");
  });
});
