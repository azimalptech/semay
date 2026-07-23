"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { httpsCallable } from "firebase/functions";
import { clientFunctions } from "@/lib/firebaseClient";
import type { ClientDict } from "@/lib/l10n";

interface DecideResult {
  sent?: number;
  failed?: number;
}

export function RequestActions({ requestId, t }: { requestId: string; t: ClientDict }) {
  const router = useRouter();
  const [busy, setBusy] = useState<"approve" | "reject" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [sentCount, setSentCount] = useState<number | null>(null);

  async function decide(approve: boolean) {
    setBusy(approve ? "approve" : "reject");
    setError(null);
    try {
      const decideNotificationRequest = httpsCallable<
        { requestId: string; approve: boolean },
        DecideResult
      >(clientFunctions, "decideNotificationRequest");
      const res = await decideNotificationRequest({ requestId, approve });
      if (approve && typeof res.data.sent === "number") {
        setSentCount(res.data.sent);
      }
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : t.decideRequestFailed);
      setBusy(null);
    }
  }

  if (sentCount !== null) {
    return (
      <p className="text-sm text-green-700">
        {t.requestApprovedSentPrefix} {sentCount}
      </p>
    );
  }

  return (
    <div className="space-y-2">
      {error && <p className="text-sm text-red-600">{error}</p>}
      <div className="flex gap-2">
        <button
          onClick={() => decide(true)}
          disabled={busy !== null}
          className="rounded-md bg-gray-900 px-3 py-1.5 text-sm font-medium text-white disabled:opacity-50"
        >
          {busy === "approve" ? t.approving : t.approve}
        </button>
        <button
          onClick={() => decide(false)}
          disabled={busy !== null}
          className="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-900 disabled:opacity-50"
        >
          {busy === "reject" ? t.rejecting : t.reject}
        </button>
      </div>
    </div>
  );
}
