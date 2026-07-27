"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import type { ClientDict } from "@/lib/l10n";

export function CreateStoreForm({ t }: { t: ClientDict }) {
  const router = useRouter();
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [tagline, setTagline] = useState("");
  const [address, setAddress] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);

    try {
      const res = await fetch("/api/stores", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, phone, tagline, address }),
      });
      if (!res.ok) {
        setError(t.failedCreateStore);
        return;
      }
      setName("");
      setPhone("");
      setTagline("");
      setAddress("");
      router.refresh();
    } catch {
      setError(t.failedCreateStore);
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="space-y-3 rounded-lg border border-gray-200 bg-white p-6"
    >
      <h2 className="text-sm font-semibold text-gray-900">{t.createStore}</h2>
      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="grid grid-cols-2 gap-3">
        <input
          required
          placeholder={t.name}
          value={name}
          onChange={(e) => setName(e.target.value)}
          className="rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
        />
        <input
          required
          placeholder={t.phone}
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          className="rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
        />
        <input
          placeholder={t.tagline}
          value={tagline}
          onChange={(e) => setTagline(e.target.value)}
          className="rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
        />
        <input
          placeholder={t.address}
          value={address}
          onChange={(e) => setAddress(e.target.value)}
          className="rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
        />
      </div>

      <button
        type="submit"
        disabled={submitting}
        className="rounded-md bg-gray-900 px-3 py-2 text-sm font-medium text-white disabled:opacity-50"
      >
        {submitting ? t.creating : t.createStore}
      </button>
    </form>
  );
}
