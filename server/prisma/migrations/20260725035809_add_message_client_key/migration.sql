-- Add client-generated idempotency key for the offline outbox (Phase 9b).
ALTER TABLE `messages` ADD COLUMN `clientKey` VARCHAR(64) NULL;
CREATE UNIQUE INDEX `messages_clientKey_key` ON `messages`(`clientKey`);
