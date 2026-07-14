export interface SmsProvider {
  sendSms(phone: string, message: string): Promise<void>;
}

// Placeholder only — logs instead of sending. Replace with the real SMS
// gateway integration (see docs/01_ARCHITECTURE.md §2).
export class LoggingSmsProvider implements SmsProvider {
  async sendSms(phone: string, message: string): Promise<void> {
    console.log(`[LoggingSmsProvider] would send SMS to ${phone}: ${message}`);
  }
}

export const smsProvider: SmsProvider = new LoggingSmsProvider();
