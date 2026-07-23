import { defineSecret } from "firebase-functions/params";

export interface SmsProvider {
  sendSms(phone: string, message: string, simIndex?: number | null): Promise<void>;
}

// Placeholder — logs instead of sending. Kept around as a fallback for local
// emulator runs, where the secrets below aren't available.
export class LoggingSmsProvider implements SmsProvider {
  async sendSms(phone: string, message: string, simIndex?: number | null): Promise<void> {
    console.log(
      `[LoggingSmsProvider] would send SMS to ${phone}${simIndex != null ? ` via SIM ${simIndex}` : ""}: ${message}`,
    );
  }
}

// Credentials for the Android SMS Gateway app's cloud-relay API
// (capcom6/android-sms-gateway) — a phone running that app, with Cloud
// Server mode enabled, acting as the actual SMS sender. Declared as
// Firebase secrets (Secret Manager), never committed to source; any
// function that calls sendSms must list both in its `secrets: [...]`
// option or these will read as empty strings at runtime.
export const smsGatewayUsername = defineSecret("SMS_GATEWAY_USERNAME");
export const smsGatewayPassword = defineSecret("SMS_GATEWAY_PASSWORD");

export class SmsGatewayProvider implements SmsProvider {
  async sendSms(phone: string, message: string, simIndex?: number | null): Promise<void> {
    const username = smsGatewayUsername.value();
    const password = smsGatewayPassword.value();
    const auth = Buffer.from(`${username}:${password}`).toString("base64");

    const response = await fetch("https://api.sms-gate.app/3rdparty/v1/message", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Basic ${auth}`,
      },
      body: JSON.stringify({
        textMessage: { text: message },
        phoneNumbers: [phone],
        // Selects which SIM slot on the gateway device sends this message
        // (0-based) — only meaningful on a dual-SIM device with a second SIM
        // active in the gateway app. Omitted entirely when null so the
        // gateway falls back to its own default SIM, same as before this
        // parameter existed.
        ...(simIndex != null ? { simNumber: simIndex } : {}),
      }),
    });

    if (!response.ok) {
      const body = await response.text();
      throw new Error(`SMS gateway request failed (${response.status}): ${body}`);
    }
  }
}

// The local Functions emulator doesn't have these secrets configured (no
// .secret.local file set up), so unconditionally using SmsGatewayProvider
// would make sendOtp fail every local dev run with bad-credentials errors
// from the gateway. Real SMS only in a real deployment; emulator keeps
// logging the code to the console like before.
const isEmulator = process.env.FUNCTIONS_EMULATOR === "true";
export const smsProvider: SmsProvider = isEmulator
  ? new LoggingSmsProvider()
  : new SmsGatewayProvider();
