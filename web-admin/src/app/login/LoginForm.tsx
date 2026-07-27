"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import type { ClientDict, Lang } from "@/lib/l10n";
import { setLanguage } from "@/lib/l10nActions";

type Step = "phone" | "code";

export function LoginForm({ lang, t }: { lang: Lang; t: ClientDict }) {
  const router = useRouter();
  const [step, setStep] = useState<Step>("phone");
  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  // Dev-mode only: the API echoes the OTP here (OTP_DEV_MODE=true) instead of
  // sending a real SMS, so local testing can log in without a gateway.
  // Production never returns this field, so this line simply stays hidden.
  const [devCode, setDevCode] = useState<string | null>(null);

  async function handleSendCode(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);

    try {
      const res = await fetch("/api/session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ step: "send", phone: phone.trim() }),
      });
      if (!res.ok) {
        setError(t.otpSendFailed);
        return;
      }
      const data = await res.json().catch(() => ({}));
      setDevCode(typeof data?.devCode === "string" ? data.devCode : null);
      setStep("code");
    } catch {
      setError(t.otpSendFailed);
    } finally {
      setSubmitting(false);
    }
  }

  async function handleVerify(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);

    try {
      const res = await fetch("/api/session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ step: "verify", phone: phone.trim(), code: code.trim() }),
      });

      if (!res.ok) {
        setError(res.status === 403 ? t.notAuthorized : t.invalidCode);
        return;
      }

      router.push("/stores");
      router.refresh();
    } catch {
      setError(t.invalidCode);
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-gray-50">
      <form
        onSubmit={step === "phone" ? handleSendCode : handleVerify}
        className="w-full max-w-sm space-y-4 rounded-lg border border-gray-200 bg-white p-8 shadow-sm"
      >
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-semibold text-gray-900">{t.appName}</h1>
          <select
            value={lang}
            onChange={(e) => setLanguage(e.target.value as Lang)}
            className="rounded-md border border-gray-300 bg-white px-2 py-1 text-sm text-gray-700"
          >
            <option value="tk">Türkmen</option>
            <option value="ru">Русский</option>
          </select>
        </div>

        {error && <p className="text-sm text-red-600">{error}</p>}

        {step === "phone" ? (
          <div className="space-y-1">
            <label htmlFor="phone" className="block text-sm font-medium text-gray-700">
              {t.phoneNumber}
            </label>
            <input
              id="phone"
              type="tel"
              required
              placeholder="+993..."
              value={phone}
              onChange={(e) => setPhone(e.target.value)}
              className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
            />
          </div>
        ) : (
          <>
            {devCode && (
              <p className="rounded-md bg-amber-50 px-3 py-2 text-sm font-medium text-amber-800">
                {t.devCodeHint} <span className="font-mono">{devCode}</span>
              </p>
            )}
            <p className="text-sm text-gray-500">
              {t.codeSentPrefix} {phone}{" "}
              <button
                type="button"
                onClick={() => {
                  setStep("phone");
                  setCode("");
                  setError(null);
                }}
                className="font-medium text-gray-900 underline"
              >
                {t.changeNumber}
              </button>
            </p>
            <div className="space-y-1">
              <label htmlFor="code" className="block text-sm font-medium text-gray-700">
                {t.codeLabel}
              </label>
              <input
                id="code"
                type="text"
                inputMode="numeric"
                required
                autoFocus
                value={code}
                onChange={(e) => setCode(e.target.value)}
                className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
              />
            </div>
          </>
        )}

        <button
          type="submit"
          disabled={submitting}
          className="w-full rounded-md bg-gray-900 px-3 py-2 text-sm font-medium text-white disabled:opacity-50"
        >
          {step === "phone"
            ? submitting
              ? t.sendingCode
              : t.sendCode
            : submitting
              ? t.verifying
              : t.verifyCode}
        </button>
      </form>
    </div>
  );
}
