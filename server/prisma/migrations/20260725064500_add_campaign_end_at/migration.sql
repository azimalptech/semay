-- Campaign end date: after it passes, new accepted orders no longer count
-- toward the store's leaderboard (standings freeze). NULL = open-ended.
ALTER TABLE `stores` ADD COLUMN `campaignEndAt` DATETIME(3) NULL AFTER `campaignStartAt`;
