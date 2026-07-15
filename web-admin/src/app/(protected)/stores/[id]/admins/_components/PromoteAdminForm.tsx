"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { httpsCallable } from "firebase/functions";
import { clientFunctions } from "@/lib/firebaseClient";

interface LookupResult {
  uid: string;
  name: string;
  phone: string;
}

export function PromoteAdminForm({ storeId }: { storeId: string }) {
  const router = useRouter();
  const [phone, setPhone] = useState("");
  const [result, setResult] = useState<LookupResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [looking, setLooking] = useState(false);
  const [promoting, setPromoting] = useState(false);

  async function handleLookup(e: React.FormEvent) {
    e.preventDefault();
    setLooking(true);
    setError(null);
    setResult(null);

    try {
      const res = await fetch(`/api/users/lookup?phone=${encodeURIComponent(phone.trim())}`);
      if (!res.ok) {
        setError(res.status === 404 ? "No account found with that phone number." : "Lookup failed.");
        return;
      }
      setResult(await res.json());
    } finally {
      setLooking(false);
    }
  }

  async function handlePromote() {
    if (!result) return;
    setPromoting(true);
    setError(null);

    try {
      const setStoreAdmin = httpsCallable(clientFunctions, "setStoreAdmin");
      await setStoreAdmin({ storeId, userId: result.uid, grant: true });
      setResult(null);
      setPhone("");
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to promote user");
    } finally {
      setPromoting(false);
    }
  }

  return (
    <div className="space-y-3 rounded-lg border border-gray-200 bg-white p-6">
      <h2 className="text-sm font-semibold text-gray-900">Promote an admin</h2>
      {error && <p className="text-sm text-red-600">{error}</p>}

      <form onSubmit={handleLookup} className="flex gap-2">
        <input
          required
          placeholder="Phone number"
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          className="flex-1 rounded-md border border-gray-300 px-3 py-2 text-sm"
        />
        <button
          type="submit"
          disabled={looking}
          className="rounded-md border border-gray-300 px-3 py-2 text-sm disabled:opacity-50"
        >
          {looking ? "Looking up..." : "Look up"}
        </button>
      </form>

      {result && (
        <div className="flex items-center justify-between rounded-md bg-gray-50 px-3 py-2 text-sm">
          <span>
            {result.name} — {result.phone}
          </span>
          <button
            onClick={handlePromote}
            disabled={promoting}
            className="rounded-md bg-gray-900 px-3 py-1.5 text-sm font-medium text-white disabled:opacity-50"
          >
            {promoting ? "Promoting..." : "Promote"}
          </button>
        </div>
      )}
    </div>
  );
}
