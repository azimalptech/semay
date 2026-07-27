import Link from "next/link";
import { prisma } from "@/lib/db";
import { getTranslations, toClientDict } from "@/lib/l10n";
import { requireSuperAdmin } from "@/lib/session";
import { CreateStoreForm } from "./_components/CreateStoreForm";

interface StoreRow {
  id: string;
  name: string;
  phone: string;
  active: boolean;
  adminCount: number;
}

async function getStores(): Promise<StoreRow[]> {
  const stores = await prisma.store.findMany({
    orderBy: { createdAt: "desc" },
    select: {
      id: true,
      name: true,
      phone: true,
      active: true,
      _count: { select: { admins: true } },
    },
  });
  return stores.map((s) => ({
    id: s.id,
    name: s.name,
    phone: s.phone,
    active: s.active,
    adminCount: s._count.admins,
  }));
}

export default async function StoresPage() {
  // Defense in depth — see dashboard/page.tsx's comment; layouts don't
  // re-run on client-side navigation, so per-page checks are what actually
  // makes session revocation take effect promptly on this page.
  await requireSuperAdmin();
  const t = await getTranslations();
  const stores = await getStores();

  return (
    <div className="mx-auto max-w-3xl space-y-8">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">{t.storesTitle}</h1>
        <p className="text-sm text-gray-500">{t.storesDesc}</p>
      </div>

      <CreateStoreForm t={toClientDict(t)} />

      <div className="overflow-hidden rounded-lg border border-gray-200 bg-white">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-gray-200 bg-gray-50 text-gray-500">
            <tr>
              <th className="px-4 py-2 font-medium">{t.name}</th>
              <th className="px-4 py-2 font-medium">{t.phone}</th>
              <th className="px-4 py-2 font-medium">{t.admins}</th>
              <th className="px-4 py-2 font-medium">{t.status}</th>
              <th className="px-4 py-2 font-medium"></th>
            </tr>
          </thead>
          <tbody>
            {stores.length === 0 && (
              <tr>
                <td colSpan={5} className="px-4 py-6 text-center text-gray-400">
                  {t.noStoresYet}
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
                    {store.active ? t.active : t.inactive}
                  </span>
                </td>
                <td className="px-4 py-2 text-right">
                  <Link
                    href={`/stores/${store.id}/admins`}
                    className="text-sm font-medium text-gray-700 underline hover:text-gray-900"
                  >
                    {t.manageAdmins}
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
