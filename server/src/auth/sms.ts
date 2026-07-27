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

/** capcom6 / sms-gate.app HTTP integration. Works with any of the gateway's
 * modes — set SMS_GATEWAY_URL to the base that exposes `/message` with HTTP
 * Basic auth: the phone's LAN address (Local Server), a self-hosted relay, or
 * the cloud relay `https://api.sms-gate.app/3rdparty/v1` (Cloud "Connect"). SMS
 * here is OTP-only (one message at a time), so it sends directly — the
 * sms_dispatch_queue/cursor tables are vestigial (they existed for Firebase-era
 * bulk pacing that this codebase no longer does). */
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
