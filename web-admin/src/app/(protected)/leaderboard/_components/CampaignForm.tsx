"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import type { ClientDict } from "@/lib/l10n";

interface StoreCampaign {
  id: string;
  name: string;
  campaignStartAtMillis: number | null;
  campaignEndAtMillis: number | null;
  campaignImageUrl: string | null;
}

function toDateInputValue(millis: number | null): string {
  if (millis == null) return "";
  return new Date(millis).toISOString().slice(0, 10);
}

// The campaign is inclusive of the whole end day, so store the end at the last
// millisecond of the picked date (UTC) — mirrors how the start is stored at the
// day's first millisecond (midnight UTC).
function endDateToMillis(dateStr: string): number {
  return new Date(`${dateStr}T23:59:59.999Z`).getTime();
}

// Combines the campaign-start-date and gift-image controls into one form
// because both are scoped to whichever store is currently selected — keeping
// them as two independent components (as they were when the campaign was
// global) would mean two separate store selectors that could drift out of
// sync with each other.
export function CampaignForm({
  initialStores,
  t,
}: {
  initialStores: StoreCampaign[];
  t: ClientDict;
}) {
  const router = useRouter();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [stores, setStores] = useState(initialStores);
  const [selectedId, setSelectedId] = useState(initialStores[0]?.id ?? "");
  const selected = stores.find((s) => s.id === selectedId) ?? null;

  const [date, setDate] = useState(toDateInputValue(selected?.campaignStartAtMillis ?? null));
  const [endDate, setEndDate] = useState(toDateInputValue(selected?.campaignEndAtMillis ?? null));
  const [savingDate, setSavingDate] = useState(false);
  const [dateError, setDateError] = useState<string | null>(null);
  const [dateSaved, setDateSaved] = useState(false);

  const [imageBusy, setImageBusy] = useState(false);
  const [imageError, setImageError] = useState<string | null>(null);

  function handleSelectStore(id: string) {
    setSelectedId(id);
    const store = stores.find((s) => s.id === id);
    setDate(toDateInputValue(store?.campaignStartAtMillis ?? null));
    setEndDate(toDateInputValue(store?.campaignEndAtMillis ?? null));
    setDateError(null);
    setDateSaved(false);
    setImageError(null);
  }

  async function handleDateSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!date || !selected) return;
    // An empty end date clears it (open-ended). Otherwise it must be on/after
    // the start — mirror the server's guard so the user gets an inline error.
    const startAtMillis = new Date(date).getTime();
    const endAtMillis = endDate ? endDateToMillis(endDate) : null;
    if (endAtMillis !== null && endAtMillis < startAtMillis) {
      setDateError(t.saveDateFailed);
      return;
    }
    setSavingDate(true);
    setDateError(null);
    setDateSaved(false);

    try {
      const res = await fetch("/api/leaderboard/campaign-start", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ storeId: selected.id, startAtMillis, endAtMillis }),
      });
      if (!res.ok) {
        setDateError(t.saveDateFailed);
        return;
      }
      setStores((prev) =>
        prev.map((s) =>
          s.id === selected.id
            ? { ...s, campaignStartAtMillis: startAtMillis, campaignEndAtMillis: endAtMillis }
            : s,
        ),
      );
      setDateSaved(true);
    } catch {
      setDateError(t.saveDateFailed);
    } finally {
      setSavingDate(false);
    }
  }

  async function handleFileSelected(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file || !selected) return;
    setImageBusy(true);
    setImageError(null);

    try {
      const formData = new FormData();
      formData.append("file", file);
      formData.append("storeId", selected.id);
      const res = await fetch("/api/leaderboard/gift-image", {
        method: "POST",
        body: formData,
      });
      if (!res.ok) {
        setImageError(t.uploadFailed);
        return;
      }
      const data = await res.json();
      setStores((prev) =>
        prev.map((s) => (s.id === selected.id ? { ...s, campaignImageUrl: data.campaignImageUrl } : s)),
      );
      router.refresh();
    } finally {
      setImageBusy(false);
      if (fileInputRef.current) fileInputRef.current.value = "";
    }
  }

  async function handleRemoveImage() {
    if (!selected) return;
    setImageBusy(true);
    setImageError(null);
    try {
      const res = await fetch(
        `/api/leaderboard/gift-image?storeId=${encodeURIComponent(selected.id)}`,
        { method: "DELETE" },
      );
      if (!res.ok) {
        setImageError(t.uploadFailed);
        return;
      }
      setStores((prev) =>
        prev.map((s) => (s.id === selected.id ? { ...s, campaignImageUrl: null } : s)),
      );
      router.refresh();
    } finally {
      setImageBusy(false);
    }
  }

  if (stores.length === 0) {
    return (
      <div className="space-y-3 rounded-lg border border-gray-200 bg-white p-6">
        <h2 className="text-sm font-semibold text-gray-900">{t.campaignStartLabel}</h2>
        <p className="text-sm text-gray-400">{t.noStoresForOrder}</p>
      </div>
    );
  }

  return (
    <div className="space-y-3 rounded-lg border border-gray-200 bg-white p-6">
      <h2 className="text-sm font-semibold text-gray-900">{t.selectStoreForCampaign}</h2>
      <select
        value={selectedId}
        onChange={(e) => handleSelectStore(e.target.value)}
        className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
      >
        {stores.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name}
          </option>
        ))}
      </select>

      <div className="border-t border-gray-100 pt-4">
        <h3 className="text-sm font-semibold text-gray-900">{t.campaignStartLabel}</h3>
        <p className="text-sm text-gray-500">{t.campaignStartDesc}</p>
        {dateError && <p className="text-sm text-red-600">{dateError}</p>}
        {dateSaved && <p className="text-sm text-green-700">{t.dateSaved}</p>}

        <form onSubmit={handleDateSubmit} className="mt-2 space-y-3">
          <input
            type="date"
            required
            value={date}
            max={endDate || undefined}
            onChange={(e) => {
              setDate(e.target.value);
              setDateSaved(false);
            }}
            className="w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
          />

          <div>
            <h3 className="text-sm font-semibold text-gray-900">{t.campaignEndLabel}</h3>
            <p className="text-sm text-gray-500">{t.campaignEndDesc}</p>
            <div className="mt-1 flex items-center gap-2">
              <input
                type="date"
                value={endDate}
                min={date || undefined}
                onChange={(e) => {
                  setEndDate(e.target.value);
                  setDateSaved(false);
                }}
                className="flex-1 rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900"
              />
              {endDate ? (
                <button
                  type="button"
                  onClick={() => {
                    setEndDate("");
                    setDateSaved(false);
                  }}
                  className="text-sm text-gray-400 underline hover:text-gray-600"
                >
                  ✕
                </button>
              ) : (
                <span className="text-xs text-gray-400">{t.campaignNoEnd}</span>
              )}
            </div>
          </div>

          <button
            type="submit"
            disabled={savingDate || !date}
            className="w-full rounded-md bg-gray-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
          >
            {savingDate ? t.savingDate : t.saveDate}
          </button>
        </form>
      </div>

      <div className="border-t border-gray-100 pt-4">
        <h3 className="text-sm font-semibold text-gray-900">{t.giftImageLabel}</h3>
        <p className="text-sm text-gray-500">{t.giftImageDesc}</p>
        {imageError && <p className="text-sm text-red-600">{imageError}</p>}

        <div className="mt-2">
          {selected?.campaignImageUrl ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={selected.campaignImageUrl}
              alt=""
              className="aspect-[3/2] w-full max-w-xs rounded-md object-cover"
            />
          ) : (
            <p className="text-sm text-gray-400">{t.noImageUploaded}</p>
          )}
        </div>

        <div className="mt-2 flex gap-2">
          <input
            ref={fileInputRef}
            type="file"
            accept="image/*"
            onChange={handleFileSelected}
            disabled={imageBusy}
            className="text-sm text-gray-900"
          />
          {selected?.campaignImageUrl && (
            <button
              onClick={handleRemoveImage}
              disabled={imageBusy}
              className="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-900 disabled:opacity-50"
            >
              {imageBusy ? t.removing : t.remove}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
