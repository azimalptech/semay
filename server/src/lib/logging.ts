import path from "node:path";

import type { TransportTargetOptions } from "pino";

import { config } from "../config.js";

export const LOG_DIR = path.resolve(config.LOG_DIR);

/** Pino transport targets: always a rotating JSON file on disk, plus a
 * human-readable console stream outside production. pino-roll creates LOG_DIR
 * itself and prunes to LOG_RETENTION_DAYS files, so logs can't grow unbounded
 * on the server. */
export function logTargets(): TransportTargetOptions[] {
  const targets: TransportTargetOptions[] = [
    {
      target: "pino-roll",
      level: config.LOG_LEVEL,
      options: {
        file: path.join(LOG_DIR, "app"),
        extension: ".log",
        frequency: "daily",
        dateFormat: "yyyy-MM-dd",
        mkdir: true,
        limit: { count: config.LOG_RETENTION_DAYS },
      },
    },
  ];

  if (process.env.NODE_ENV !== "production") {
    targets.push({ target: "pino-pretty", level: config.LOG_LEVEL, options: {} });
  }

  return targets;
}
