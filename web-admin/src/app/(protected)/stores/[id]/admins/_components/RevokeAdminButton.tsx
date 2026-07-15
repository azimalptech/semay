"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { httpsCallable } from "firebase/functions";
import { clientFunctions } from "@/lib/firebaseClient";

export function RevokeAdminButton({ storeId, userId }: { storeId: string; userId: string }) {
  const router = useRouter();
  const [revoking, setRevoking] = useState(false);

  async function handleRevoke() {
    setRevoking(true);
    try {
      const setStoreAdmin = httpsCallable(clientFunctions, "setStoreAdmin");
      await setStoreAdmin({ storeId, userId, grant: false });
      router.refresh();
    } finally {
      setRevoking(false);
    }
  }

  return (
    <button
      onClick={handleRevoke}
      disabled={revoking}
      className="text-sm font-medium text-red-600 underline hover:text-red-700 disabled:opacity-50"
    >
      {revoking ? "Revoking..." : "Revoke"}
    </button>
  );
}
