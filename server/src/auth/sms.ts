import { config } from "../config.js";

export interface SmsProvider {
  send(phone: string, message: string): Promise<void>;
}

/** Logs instead of sending — used when OTP_DEV_MODE=true and no gateway creds exist yet. */
class DevLogSmsProvider implements SmsProvider {
  async send(phone: string, message: string): Promise<void> {
    // eslint-disable-next-line no-console
    console.log(`[sms:dev] → ${phone}: ${message}`);
  }
}

/** Thrown when the SMS gateway can't be reached or rejects the message, so the
 * caller can turn it into a clean client error (and clear the OTP cooldown)
 * rather than a raw 500. */
export class SmsSendError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SmsSendError";
  }
}

/** Sends through our own relay in `sms-gateway/` — set SMS_GATEWAY_URL to the
 * base that exposes `/message` with HTTP Basic auth, normally
 * `https://semaycollection.com/sms/3rdparty/v1`.
 *
 * This used to point at capcom6's cloud relay, api.sms-gate.app, which turned
 * out to be unreachable from Turkmen networks (100% packet loss from the
 * gateway handset while google.com and our own domain answered fine on the
 * same Wi-Fi), so every OTP sat queued at the relay and never sent. The wire
 * protocol is deliberately unchanged and this file needed no edit for the
 * switch — any sms-gate.app-compatible gateway still works here.
 *
 * SMS here is OTP-only (one message at a time), so it sends directly — no
 * queue or pacing cursor is involved on this side. Pacing lives in the relay
 * and the handset, where the per-SIM rate limits are (the vestigial
 * Firebase-era tables for it have been dropped from the schema). */
class GatewaySmsProvider implements SmsProvider {
  private static readonly timeoutMs = 15_000;

  async send(phone: string, message: string): Promise<void> {
    const auth = Buffer.from(
      `${config.SMS_GATEWAY_USER}:${config.SMS_GATEWAY_PASSWORD}`
    ).toString("base64");

    // A hung/slow gateway must not hang the login request — abort after 15s.
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), GatewaySmsProvider.timeoutMs);
    try {
      const res = await fetch(`${config.SMS_GATEWAY_URL}/message`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Basic ${auth}`,
        },
        body: JSON.stringify({ phoneNumbers: [phone], message }),
        signal: controller.signal,
      });
      if (!res.ok) {
        throw new SmsSendError(`SMS gateway responded ${res.status}: ${await res.text()}`);
      }
    } catch (err) {
      if (err instanceof SmsSendError) throw err;
      // Network error, DNS failure, or the abort above.
      throw new SmsSendError(`SMS gateway unreachable: ${(err as Error).message}`);
    } finally {
      clearTimeout(timer);
    }
  }
}

export const smsProvider: SmsProvider = config.OTP_DEV_MODE
  ? new DevLogSmsProvider()
  : new GatewaySmsProvider();
