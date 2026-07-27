"use client";

import { useRouter } from "next/navigation";

export function LogoutButton({ label }: { label: string }) {
  const router = useRouter();

  async function handleLogout() {
    await fetch("/api/logout", { method: "POST" });
    router.push("/login");
    router.refresh();
  }

  return (
    <button
      onClick={handleLogout}
      className="rounded-md border border-gray-300 px-3 py-1.5 text-sm hover:bg-gray-50"
    >
      {label}
    </button>
  );
}
