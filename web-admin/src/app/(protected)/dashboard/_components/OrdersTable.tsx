"use client";

import { useMemo, useState } from "react";
import type { ClientDict } from "@/lib/l10n";

export interface OrderRow {
  storeId: string;
  storeName: string;
  userPhone: string;
  itemQuantity: number;
  date: string; // YYYY-MM-DD
}

type FilterMode = "all" | "shop" | "phone";

export function OrdersTable({
  orders,
  storeNames,
  t,
}: {
  orders: OrderRow[];
  storeNames: Record<string, string>;
  t: ClientDict;
}) {
  const [mode, setMode] = useState<FilterMode>("all");
  const [selectedStore, setSelectedStore] = useState<string>("");
  const [phoneQuery, setPhoneQuery] = useState("");

  const storeIds = useMemo(
    () => Object.keys(storeNames).sort((a, b) => storeNames[a].localeCompare(storeNames[b])),
    [storeNames]
  );

  const filtered = useMemo(() => {
    if (mode === "shop" && selectedStore) {
      return orders.filter((o) => o.storeId === selectedStore);
    }
    if (mode === "phone" && phoneQuery.trim()) {
      const query = phoneQuery.trim().toLowerCase();
      return orders.filter((o) => o.userPhone.toLowerCase().includes(query));
    }
    return orders;
  }, [orders, mode, selectedStore, phoneQuery]);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex overflow-hidden rounded-md border border-gray-300">
          {(["all", "shop", "phone"] as const).map((option) => (
            <button
              key={option}
              onClick={() => setMode(option)}
              className={
                "px-3 py-1.5 text-sm font-medium " +
                (mode === option
                  ? "bg-gray-900 text-white"
                  : "bg-white text-gray-700 hover:bg-gray-50")
              }
            >
              {option === "all" ? t.filterAll : option === "shop" ? t.filterShop : t.filterByPhone}
            </button>
          ))}
        </div>

        {mode === "shop" && (
          <select
            value={selectedStore}
            onChange={(e) => setSelectedStore(e.target.value)}
            className="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-900"
          >
            <option value="">{t.allShops}</option>
            {storeIds.map((id) => (
              <option key={id} value={id}>
                {storeNames[id]}
              </option>
            ))}
          </select>
        )}

        {mode === "phone" && (
          <input
            value={phoneQuery}
            onChange={(e) => setPhoneQuery(e.target.value)}
            placeholder={t.searchPhonePlaceholder}
            className="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-900"
          />
        )}
      </div>

      <div className="overflow-hidden rounded-lg border border-gray-200 bg-white">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-gray-200 bg-gray-50 text-gray-500">
            <tr>
              <th className="px-4 py-2 font-medium">{t.date}</th>
              <th className="px-4 py-2 font-medium">{t.store}</th>
              <th className="px-4 py-2 font-medium">{t.phone}</th>
              <th className="px-4 py-2 font-medium">{t.quantity}</th>
            </tr>
          </thead>
          <tbody>
            {filtered.length === 0 && (
              <tr>
                <td colSpan={4} className="px-4 py-6 text-center text-gray-400">
                  {t.noMatchingOrders}
                </td>
              </tr>
            )}
            {filtered.map((order, i) => (
              <tr key={i} className="border-b border-gray-100 last:border-0">
                <td className="px-4 py-2 text-gray-900">{order.date}</td>
                <td className="px-4 py-2 text-gray-500">{order.storeName}</td>
                <td className="px-4 py-2 text-gray-500">{order.userPhone}</td>
                <td className="px-4 py-2 font-medium text-gray-900">{order.itemQuantity}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
