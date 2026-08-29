-- Scope `messages.clientKey` uniqueness to the chat.
--
-- It was globally UNIQUE, which turned the key into a cross-chat handle:
-- sendMessage resolved it with findUnique and returned whatever row owned it,
-- so replaying a key read back a stranger's private message from a chat the
-- caller is otherwise 403'd on. Orders mint derivable keys (`order:{id}`), so
-- the keyspace was not purely random either.
--
-- Per-chat uniqueness is what the idempotency actually requires: a genuine
-- retry from the offline outbox always targets the same chat.
DROP INDEX `messages_clientKey_key` ON `messages`;
CREATE UNIQUE INDEX `messages_chatId_clientKey_key` ON `messages`(`chatId`, `clientKey`);
