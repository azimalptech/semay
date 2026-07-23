"use client";

import { useState } from "react";
import { httpsCallable } from "firebase/functions";
import { clientFunctions } from "@/lib/firebaseClient";

interface Group {
  phone: string;
  keepUid: string;
  deleteUids: string[];
  skippedReason?: string;
}

interface Result {
  dryRun: boolean;
  duplicatePhones?: number;
  wouldDelete?: number;
  deleted?: number;
  errors?: string[];
  groups: Group[];
}

// Superadmin-only "one phone = one account" cleanup. Scan (dry run) shows the
// plan; Delete actually removes the extra accounts. See the
// cleanupDuplicateUsers Cloud Function for the safety rules.
export function DuplicateCleanup() {
  const [busy, setBusy] = useState<"scan" | "delete" | null>(null);
  const [result, setResult] = useState<Result | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function run(confirm: boolean) {
    setBusy(confirm ? "delete" : "scan");
    setError(null);
    try {
      const fn = httpsCallable<{ confirm: boolean }, Result>(
        clientFunctions,
        "cleanupDuplicateUsers"
      );
      const res = await fn({ confirm });
      setResult(res.data);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed");
    } finally {
      setBusy(null);
    }
  }

  const actionable = (result?.groups ?? []).filter(
    (g) => g.deleteUids.length > 0
  );
  const flagged = (result?.groups ?? []).filter((g) => g.skippedReason);

  return (
    <div className="space-y-4 rounded-lg border border-gray-200 bg-white p-6">
      <div>
        <h2 className="text-sm font-medium text-gray-900">
          Duplicate accounts (same phone)
        </h2>
        <p className="mt-1 text-sm text-gray-500">
          Finds any phone number owned by more than one account and removes the
          extras, keeping one per number. Never deletes an admin/store account.
          Scan first to preview.
        </p>
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}

      <div className="flex gap-2">
        <button
          onClick={() => run(false)}
          disabled={busy !== null}
          className="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-900 disabled:opacity-50"
        >
          {busy === "scan" ? "Scanning…" : "Scan (dry run)"}
        </button>
        <button
          onClick={() => {
            if (
              confirm(
                `Permanently delete ${result?.wouldDelete ?? 0} duplicate account(s)? This cannot be undone.`
              )
            ) {
              run(true);
            }
          }}
          disabled={busy !== null || !result || (result.wouldDelete ?? 0) === 0}
          className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-medium text-white disabled:opacity-50"
        >
          {busy === "delete" ? "Deleting…" : "Delete duplicates"}
        </button>
      </div>

      {result && (
        <div className="space-y-3 text-sm">
          {result.dryRun ? (
            <p className="text-gray-700">
              Found <b>{result.duplicatePhones ?? 0}</b> phone number(s) with
              duplicates — <b>{result.wouldDelete ?? 0}</b> account(s) would be
              deleted.
            </p>
          ) : (
            <p className="font-medium text-green-700">
              Deleted {result.deleted ?? 0} duplicate account(s).
              {(result.errors?.length ?? 0) > 0 &&
                ` ${result.errors!.length} error(s).`}
            </p>
          )}

          {flagged.length > 0 && (
            <div className="rounded-md bg-amber-50 p-3 text-amber-800">
              <p className="font-medium">Skipped — needs manual review:</p>
              <ul className="mt-1 list-disc pl-5">
                {flagged.map((g) => (
                  <li key={g.phone}>
                    {g.phone}: {g.skippedReason}
                  </li>
                ))}
              </ul>
            </div>
          )}

          {actionable.length > 0 && (
            <div className="space-y-2">
              {actionable.map((g) => (
                <div
                  key={g.phone}
                  className="rounded-md border border-gray-100 bg-gray-50 p-3"
                >
                  <p className="font-medium text-gray-900">{g.phone}</p>
                  <p className="text-gray-600">
                    keep <code className="text-xs">{g.keepUid}</code>
                  </p>
                  <p className="text-red-600">
                    delete{" "}
                    {g.deleteUids.map((u) => (
                      <code key={u} className="mr-1 text-xs">
                        {u}
                      </code>
                    ))}
                  </p>
                </div>
              ))}
            </div>
          )}

          {result.errors && result.errors.length > 0 && (
            <div className="rounded-md bg-red-50 p-3 text-red-700">
              <ul className="list-disc pl-5">
                {result.errors.map((e, i) => (
                  <li key={i}>{e}</li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
