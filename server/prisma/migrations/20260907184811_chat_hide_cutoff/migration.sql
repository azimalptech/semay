-- Per-side chat delete now hides history, not just the list row.
--
-- DELETE /chats/:id used to stamp hiddenBy{User,Admin}At and nothing else: the
-- deleting side's thread, its WS snapshot and ?before= paging all kept
-- returning every old message, and the moment the other side wrote again the
-- whole history was back in that side's list. These columns record the newest
-- messages.id that existed at the instant of the hide (taken under the same
-- chats-row X lock sendMessage uses, so a concurrent send lands wholly before
-- or wholly after it); everything at or below it is filtered out for that
-- side in chats/service.ts. Keyed by id rather than by createdAt vs hiddenAt
-- because ids are already the ordering/paging key and never tie or cross
-- between API processes the way two `new Date()`s can.
--
-- Deliberately NOT backfilled (owner's decision): a chat hidden before this
-- release keeps its list-only hide (NULL = nothing hidden) rather than losing
-- history the user never asked to lose.
-- AlterTable
ALTER TABLE `chats` ADD COLUMN `hiddenByAdminUpToId` BIGINT NULL,
    ADD COLUMN `hiddenByUserUpToId` BIGINT NULL;
