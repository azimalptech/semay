import Link from "next/link";
import { adminDb } from "@/lib/firebaseAdmin";
import { CreateStoreForm } from "./_components/CreateStoreForm";

interface StoreRow {
  id: string;
  name: string;
  phone: string;
  active: boolean;
  adminCount: number;
}

async function getStores(): Promise<StoreRow[]> {
  const snap = await adminDb.collection("stores").orderBy("createdAt", "desc").get();
  return snap.docs.map((doc) => {
    const data = doc.data();
    return {
      id: doc.id,
      name: data.name as string,
      phone: (data.phone as string) ?? "",
      active: (data.active as boolean) ?? true,
      adminCount: ((data.adminIds as string[]) ?? []).length,
    };
  });
}

export default async function StoresPage() {
  const stores = await getStores();

  return (
    <div className="mx-auto max-w-3xl space-y-8">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">Stores</h1>
        <p className="text-sm text-gray-500">Create stores and manage their admins.</p>
      </div>

      <CreateStoreForm />

      <div className="overflow-hidden rounded-lg border border-gray-200 bg-white">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-gray-200 bg-gray-50 text-gray-500">
            <tr>
              <th className="px-4 py-2 font-medium">Name</th>
              <th className="px-4 py-2 font-medium">Phone</th>
              <th className="px-4 py-2 font-medium">Admins</th>
              <th className="px-4 py-2 font-medium">Status</th>
              <th className="px-4 py-2 font-medium"></th>
            </tr>
          </thead>
          <tbody>
            {stores.length === 0 && (
              <tr>
                <td colSpan={5} className="px-4 py-6 text-center text-gray-400">
                  No stores yet.
                </td>
              </tr>
            )}
            {stores.map((store) => (
              <tr key={store.id} className="border-b border-gray-100 last:border-0">
                <td className="px-4 py-2 text-gray-900">{store.name}</td>
                <td className="px-4 py-2 text-gray-500">{store.phone}</td>
                <td className="px-4 py-2 text-gray-500">{store.adminCount}</td>
                <td className="px-4 py-2">
                  <span
                    className={
                      store.active
                        ? "rounded-full bg-green-100 px-2 py-0.5 text-xs text-green-700"
                        : "rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-500"
                    }
                  >
                    {store.active ? "active" : "inactive"}
                  </span>
                </td>
                <td className="px-4 py-2 text-right">
                  <Link
                    href={`/stores/${store.id}/admins`}
                    className="text-sm font-medium text-gray-700 underline hover:text-gray-900"
                  >
                    Manage admins
                  </Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
