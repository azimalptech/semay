import type { Language } from "@prisma/client";

/** The server's own string table — the counterpart of the app's
 * `mobile/lib/core/l10n.dart`.
 *
 * SeMay ships Turkmen and Russian ONLY, deliberately no English (l10n.dart,
 * and `res/values` / `res/values-ru` for the Android channel names). Anything
 * the server WRITES for a person to read therefore has to exist in both, and
 * the wording here mirrors l10n.dart so a push and the screen it opens do not
 * disagree: `orderAccepted` is l10n.dart's `orderAccepted`, `newMessage`
 * matches the chat channel's description, `newOrder` the orders channel's.
 *
 * Which language a given string gets:
 *   - a push picks the RECIPIENT's `users.language` (notifications/push.ts
 *     `sendLocalizedPushToUsers`, which groups recipients by it);
 *   - the order's chat message is one persisted row that BOTH the customer and
 *     the store admin read, so it cannot be per-reader — it is written in the
 *     customer's language, since it is the customer the message informs (the
 *     admin is reading back their own tap).
 *
 * `tk` is the fallback for a recipient whose row is missing, matching the
 * schema default (`User.language @default(tk)`).
 */
export const DEFAULT_LANGUAGE: Language = "tk";

export interface Copy {
  /** Chat push title when neither the sender's name nor the store's is set. */
  newMessage: string;
  /** Order push title, to the superadmins. */
  newOrder: string;
  /** Order push body. */
  orderPlaced: (who: string, quantity: number) => string;
  /** The system message acceptOrder posts into the chat. */
  orderAccepted: string;
}

export const COPY: Record<Language, Copy> = {
  tk: {
    newMessage: "Täze habar",
    newOrder: "Täze sargyt",
    orderPlaced: (who, quantity) => `${who} sargyt etdi (${quantity} haryt)`,
    orderAccepted: "Sargyt kabul edildi ✅",
  },
  ru: {
    newMessage: "Новое сообщение",
    newOrder: "Новый заказ",
    orderPlaced: (who, quantity) => `Заказ от ${who} (${quantity} шт.)`,
    orderAccepted: "Заказ принят ✅",
  },
};

/** The table for `language`, falling back to Turkmen for null/undefined — a
 * recipient whose row vanished between the lookup and the send, or a caller
 * that has no language in hand. */
export function copyFor(language?: Language | null): Copy {
  return COPY[language ?? DEFAULT_LANGUAGE] ?? COPY[DEFAULT_LANGUAGE];
}
