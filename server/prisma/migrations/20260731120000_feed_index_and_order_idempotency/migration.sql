-- The global /feed filters `type IN ('image','carousel')` and orders by
-- createdAt. The existing (type, createdAt) index only orders within a single
-- type, so spanning two made MariaDB drop to a full table scan + filesort.
-- Measured on 300k posts: 135ms -> 0.2ms.
CREATE INDEX `posts_createdAt_idx` ON `posts`(`createdAt`);

-- Idempotency key for accepting an order. Nullable: existing rows (and older
-- app builds that don't send one) stay valid; UNIQUE only constrains the keys
-- that are actually present, which is what makes a retried accept collapse
-- onto the original sale instead of double-counting the prize leaderboard.
ALTER TABLE `orders` ADD COLUMN `clientKey` VARCHAR(64) NULL;
CREATE UNIQUE INDEX `orders_clientKey_key` ON `orders`(`clientKey`);
