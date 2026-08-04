-- Total likes across a store's posts — the "Halananlar" stat on the store detail
-- header. Denormalized for the same reason postsCount/reelsCount are: the header
-- is read constantly, and summing every post's likesCount per load would scale
-- with catalogue size. Maintained inside the same transaction as the per-post
-- like toggle (posts/service.ts setToggle).
--
-- Deliberately NOT backfilled from existing post likes (owner's decision): it
-- starts at 0 and counts forward from here. setToggle's decrement is clamped at
-- zero so unliking a pre-existing like can't drive the total negative.
ALTER TABLE `stores` ADD COLUMN `likesCount` INTEGER NOT NULL DEFAULT 0;
