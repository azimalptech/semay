-- Sessions last until logout.
--
-- Refresh-token rotation was strictly single-use: the presented row was
-- revoked and a successor created, and a client that never received that
-- response (receive timeout, app suspended mid-request, a second browser tab
-- racing on the same cookie) was left holding a token the server had already
-- retired — its next refresh got 401 and the device was logged out, roughly
-- every access-token TTL. Two new columns carry the replacement contract
-- (server/src/auth/session.ts):
--
--   familyId  — id of the login's root row, inherited by every rotation and
--               every grace-issued sibling, so logout can end all of them.
--   rotatedAt — "superseded by a refresh", kept separate from revokedAt
--               ("logged out"): a rotated token is still accepted for a short
--               grace and issued a live sibling, a revoked one never is.
--
-- Rows retired under the old rule were stamped revokedAt and stay that way
-- (they were never re-accepted, and none is inside a 60 s grace by the time
-- this runs); the reaper drops them after 7 days as before.

-- familyId cannot be added NOT NULL to a populated table without a value:
-- add it nullable, make every existing row its own family, then tighten.
ALTER TABLE `sessions` ADD COLUMN `familyId` VARCHAR(36) NULL,
    ADD COLUMN `rotatedAt` DATETIME(3) NULL;

UPDATE `sessions` SET `familyId` = `id`;

ALTER TABLE `sessions` MODIFY `familyId` VARCHAR(36) NOT NULL;

-- Expiry now slides: each refresh issues its successor with a fresh window of
-- REFRESH_TOKEN_TTL_DAYS (default 730), so a token only lapses on a device that
-- has been silent that long. Live rows minted under the 30-day rule get the
-- same treatment retroactively — createdAt is their last use, since every
-- refresh created a new row — so devices already logged in are not signed out
-- on the first quiet month after this deploys. UTC_TIMESTAMP, not NOW(): Prisma
-- writes DATETIME columns in UTC, while NOW() follows the server's time zone.
UPDATE `sessions`
SET `expiresAt` = DATE_ADD(`createdAt`, INTERVAL 730 DAY)
WHERE `revokedAt` IS NULL AND `expiresAt` > UTC_TIMESTAMP(3);

-- CreateIndex
CREATE INDEX `sessions_familyId_idx` ON `sessions`(`familyId`);
