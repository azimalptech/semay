"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import type { ClientDict } from "@/lib/l10n";

export function DeleteStoreButton({
  storeId,
  storeName,
  confirmLabel,
  t,
}: {
  storeId: string;
  storeName: string;
  // Server Component-only (deleteStoreConfirmLabel takes a function, which
  // can't cross into a Client Component — see ClientDict's comment), so the
  // page computes the string and passes it down instead.
  confirmLabel: string;
  t: ClientDict;
}) {
  const router = useRouter();
  const [confirmText, setConfirmText] = useState("");
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const canDelete = confirmText === storeName && !deleting;

  async function handleDelete() {
    if (!canDelete) return;
    setDeleting(true);
    setError(null);
    try {
      const res = await fetch(`/api/stores/${storeId}`, { method: "DELETE" });
      if (!res.ok) {
        setError(t.deleteStoreFailed);
        setDeleting(false);
        return;
      }
      router.push("/stores");
      router.refresh();
    } catch {
      setError(t.deleteStoreFailed);
      setDeleting(false);
    }
  }

  return (
    <div className="space-y-3 rounded-lg border border-red-200 bg-red-50 p-6">
      <h2 className="text-sm font-semibold text-red-900">{t.deleteStoreTitle}</h2>
      <p className="text-sm text-red-700">{t.deleteStoreDesc}</p>
      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="space-y-2">
        <label className="block text-sm text-red-900">{confirmLabel}</label>
        <input
          value={confirmText}
          onChange={(e) => setConfirmText(e.target.value)}
          className="w-full rounded-md border border-red-300 bg-white px-3 py-2 text-sm text-gray-900"
        />
      </div>

      <button
        onClick={handleDelete}
        disabled={!canDelete}
        className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-medium text-white disabled:opacity-50"
      >
        {deleting ? t.deletingStore : t.deleteStore}
      </button>
    </div>
  );
}
