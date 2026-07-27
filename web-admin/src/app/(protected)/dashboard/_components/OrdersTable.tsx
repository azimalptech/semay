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

// A quick-range preset (in days) or "manual" for the from/to pickers. Presets
// beyond "all" bound the view without a server round-trip — the page already
// fetches a full year (see dashboard/page.tsx).
type RangePreset = 7 | 30 | 90 | 365 | "manual";
const PRESET_DAYS: Exclude<RangePreset, "manual">[] = [7, 30, 90, 365];

// UTC "YYYY-MM-DD", matching how order.date is derived server-side
// (createdAt.toISOString().slice(0,10)) so preset boundaries compare correctly.
function utcDaysAgo(n: number): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - n);
  return d.toISOString().slice(0, 10);
}
function utcToday(): string {
  return new Date().toISOString().slice(0, 10);
}

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
  // Range preset (defaults to 90 days, the prior fixed window). "manual" hands
  // control to the from/to pickers below.
  const [preset, setPreset] = useState<RangePreset>(90);
  // Manual bounds — used only when preset === "manual". Both are optional and
  // inclusive; the "YYYY-MM-DD" order date compares lexically, so a plain
  // string >= / <= is a correct date comparison.
  const [fromDate, setFromDate] = useState("");
  const [toDate, setToDate] = useState("");

  // Effective [from, to] the filter actually applies: a preset resolves to
  // (today - N days)..today; "manual" uses the picker bounds as-is.
  const { rangeFrom, rangeTo } =
    preset === "manual"
      ? { rangeFrom: fromDate, rangeTo: toDate }
      : { rangeFrom: utcDaysAgo(preset), rangeTo: utcToday() };

  const storeIds = useMemo(
    () => Object.keys(storeNames).sort((a, b) => storeNames[a].localeCompare(storeNames[b])),
    [storeNames]
  );

  const filtered = useMemo(() => {
    let result = orders;
    if (mode === "shop" && selectedStore) {
      result = result.filter((o) => o.storeId === selectedStore);
    } else if (mode === "phone" && phoneQuery.trim()) {
      const query = phoneQuery.trim().toLowerCase();
      result = result.filter((o) => o.userPhone.toLowerCase().includes(query));
    }
    if (rangeFrom) result = result.filter((o) => o.date >= rangeFrom);
    if (rangeTo) result = result.filter((o) => o.date <= rangeTo);
    return result;
  }, [orders, mode, selectedStore, phoneQuery, rangeFrom, rangeTo]);

  const totalQuantity = useMemo(
    () => filtered.reduce((sum, o) => sum + o.itemQuantity, 0),
    [filtered]
  );

  // Sort by date, toggled from the Date column header. "newest" (desc) is the
  // default, matching the server's orderBy. The sort is stable, so orders on
  // the same day keep their newest-first server order within that day.
  const [sortDir, setSortDir] = useState<"desc" | "asc">("desc");
  const sorted = useMemo(() => {
    const copy = [...filtered];
    copy.sort((a, b) =>
      sortDir === "desc" ? b.date.localeCompare(a.date) : a.date.localeCompare(b.date)
    );
    return copy;
  }, [filtered, sortDir]);

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

        <div className="flex overflow-hidden rounded-md border border-gray-300">
          {PRESET_DAYS.map((days) => (
            <button
              key={days}
              onClick={() => setPreset(days)}
              className={
                "px-3 py-1.5 text-sm font-medium " +
                (preset === days
                  ? "bg-gray-900 text-white"
                  : "bg-white text-gray-700 hover:bg-gray-50")
              }
            >
              {days === 7
                ? t.last7Days
                : days === 30
                  ? t.last30Days
                  : days === 90
                    ? t.last90Days
                    : t.lastYear}
            </button>
          ))}
          <button
            onClick={() => setPreset("manual")}
            className={
              "px-3 py-1.5 text-sm font-medium " +
              (preset === "manual"
                ? "bg-gray-900 text-white"
                : "bg-white text-gray-700 hover:bg-gray-50")
            }
          >
            {t.manualRange}
          </button>
        </div>

        {preset === "manual" && (
          <div className="flex items-center gap-2">
            <label className="flex items-center gap-1 text-sm text-gray-500">
              {t.dateFrom}
              <input
                type="date"
                value={fromDate}
                max={toDate || undefined}
                onChange={(e) => setFromDate(e.target.value)}
                className="rounded-md border border-gray-300 px-2 py-1.5 text-sm text-gray-900"
              />
            </label>
            <label className="flex items-center gap-1 text-sm text-gray-500">
              {t.dateTo}
              <input
                type="date"
                value={toDate}
                min={fromDate || undefined}
                onChange={(e) => setToDate(e.target.value)}
                className="rounded-md border border-gray-300 px-2 py-1.5 text-sm text-gray-900"
              />
            </label>
          </div>
        )}
      </div>

      <div className="flex flex-wrap gap-6 text-sm">
        <span className="text-gray-500">
          {t.totalOrders}: <span className="font-semibold text-gray-900">{filtered.length}</span>
        </span>
        <span className="text-gray-500">
          {t.totalItems}: <span className="font-semibold text-gray-900">{totalQuantity}</span>
        </span>
      </div>

      <div className="overflow-hidden rounded-lg border border-gray-200 bg-white">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-gray-200 bg-gray-50 text-gray-500">
            <tr>
              <th className="px-4 py-2 font-medium">
                <button
                  onClick={() => setSortDir((d) => (d === "desc" ? "asc" : "desc"))}
                  className="flex items-center gap-1 font-medium hover:text-gray-700"
                >
                  {t.date}
                  <span aria-hidden>{sortDir === "desc" ? "▼" : "▲"}</span>
                </button>
              </th>
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
            {sorted.map((order, i) => (
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
