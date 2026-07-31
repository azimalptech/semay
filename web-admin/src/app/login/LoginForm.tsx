"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import type { ClientDict, Lang } from "@/lib/l10n";
import { setLanguage } from "@/lib/l10nActions";

export function LoginForm({ lang, t }: { lang: Lang; t: ClientDict }) {
  const router = useRouter();
  const [phone, setPhone] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);

    try {
      const res = await fetch("/api/session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ phone: phone.trim(), password }),
      });
      if (!res.ok) {
        setError(t.invalidCredentials);
        return;
      }
      router.push("/stores");
      router.refresh();
    } catch {
      setError(t.invalidCredentials);
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-gray-50">
      <form
        onSubmit={handleSubmit}
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

        <div className="space-y-1">
          <label htmlFor="phone" className="block text-sm font-medium text-gray-700">
            {t.phoneNumber}
          </label>
          <input
            id="phone"
            type="tel"
            required
            autoFocus
            placeholder="+993..."
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
          />
        </div>

        <div className="space-y-1">
          <label htmlFor="password" className="block text-sm font-medium text-gray-700">
            {t.password}
          </label>
          <input
            id="password"
            type="password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
          />
        </div>

        <button
          type="submit"
          disabled={submitting}
          className="w-full rounded-md bg-gray-900 px-3 py-2 text-sm font-medium text-white disabled:opacity-50"
        >
          {submitting ? t.loggingIn : t.logIn}
        </button>
      </form>
    </div>
  );
}
