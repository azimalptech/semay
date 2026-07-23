"use client";

import { useState } from "react";
import { httpsCallable } from "firebase/functions";
import { clientFunctions } from "@/lib/firebaseClient";
import type { ClientDict } from "@/lib/l10n";

interface BroadcastResult {
  sent: number;
  failed: number;
}

export function BroadcastForm({ t }: { t: ClientDict }) {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<BroadcastResult | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSending(true);
    setError(null);
    setResult(null);

    try {
      const broadcastNotification = httpsCallable<
        { title: string; body: string },
        BroadcastResult
      >(clientFunctions, "broadcastNotification");
      const res = await broadcastNotification({ title: title.trim(), body: body.trim() });
      setResult(res.data);
      setTitle("");
      setBody("");
    } catch (err) {
      setError(err instanceof Error ? err.message : t.broadcastFailed);
    } finally {
      setSending(false);
    }
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="space-y-4 rounded-lg border border-gray-200 bg-white p-6"
    >
      {error && <p className="text-sm text-red-600">{error}</p>}
      {result && (
        <p className="text-sm text-green-700">
          {t.broadcastSentPrefix} {result.sent}
          {result.failed > 0 ? ` (${result.failed} failed)` : ""}
        </p>
      )}

      <div className="space-y-1">
        <label htmlFor="notif-title" className="block text-sm font-medium text-gray-700">
          {t.notificationTitle}
        </label>
        <input
          id="notif-title"
          required
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
        />
      </div>

      <div className="space-y-1">
        <label htmlFor="notif-body" className="block text-sm font-medium text-gray-700">
          {t.notificationBody}
        </label>
        <textarea
          id="notif-body"
          required
          rows={4}
          value={body}
          onChange={(e) => setBody(e.target.value)}
          className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
        />
      </div>

      <button
        type="submit"
        disabled={sending}
        className="rounded-md bg-gray-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
      >
        {sending ? t.sending : t.send}
      </button>
    </form>
  );
}
