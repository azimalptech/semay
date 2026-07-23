"use client";

import { useState } from "react";
import type { ClientDict } from "@/lib/l10n";

interface StoreRow {
  id: string;
  name: string;
}

export function StoreOrderForm({
  initialStores,
  t,
}: {
  initialStores: StoreRow[];
  t: ClientDict;
}) {
  const [stores, setStores] = useState(initialStores);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function persist(next: StoreRow[]) {
    setSaving(true);
    setError(null);
    try {
      const res = await fetch("/api/leaderboard/store-order", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ storeIds: next.map((s) => s.id) }),
      });
      if (!res.ok) {
        setError(t.reorderFailed);
        setStores(stores); // revert the optimistic move
        return;
      }
      setStores(next);
    } finally {
      setSaving(false);
    }
  }

  function move(index: number, direction: -1 | 1) {
    const target = index + direction;
    if (target < 0 || target >= stores.length || saving) return;
    const next = [...stores];
    [next[index], next[target]] = [next[target], next[index]];
    persist(next);
  }

  return (
    <div className="space-y-3 rounded-lg border border-gray-200 bg-white p-6">
      <h2 className="text-sm font-semibold text-gray-900">{t.storeOrderLabel}</h2>
      <p className="text-sm text-gray-500">{t.storeOrderDesc}</p>
      {error && <p className="text-sm text-red-600">{error}</p>}

      {stores.length === 0 ? (
        <p className="text-sm text-gray-400">{t.noStoresForOrder}</p>
      ) : (
        <ul className="divide-y divide-gray-100 rounded-md border border-gray-200">
          {stores.map((store, index) => (
            <li
              key={store.id}
              className="flex items-center justify-between px-3 py-2 text-sm text-gray-900"
            >
              <span>{store.name}</span>
              <div className="flex gap-1">
                <button
                  onClick={() => move(index, -1)}
                  disabled={saving || index === 0}
                  className="rounded-md border border-gray-300 px-2 py-1 text-xs disabled:opacity-30"
                  aria-label="Move up"
                >
                  ↑
                </button>
                <button
                  onClick={() => move(index, 1)}
                  disabled={saving || index === stores.length - 1}
                  className="rounded-md border border-gray-300 px-2 py-1 text-xs disabled:opacity-30"
                  aria-label="Move down"
                >
                  ↓
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
