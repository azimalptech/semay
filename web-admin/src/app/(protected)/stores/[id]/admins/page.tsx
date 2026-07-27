import { notFound } from "next/navigation";
import { prisma } from "@/lib/db";
import { getTranslations, toClientDict } from "@/lib/l10n";
import { requireSuperAdmin } from "@/lib/session";
import { PromoteAdminForm } from "./_components/PromoteAdminForm";
import { RevokeAdminButton } from "./_components/RevokeAdminButton";
import { DeleteStoreButton } from "./_components/DeleteStoreButton";

export default async function StoreAdminsPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  // Defense in depth — see dashboard/page.tsx's comment; this page reads
  // admin phone numbers and can grant/revoke store-admin rights, so it
  // needs its own check regardless of the layout's.
  await requireSuperAdmin();
  const { id: storeId } = await params;
  const t = await getTranslations();
  const clientT = toClientDict(t);

  const store = await prisma.store.findUnique({
    where: { id: storeId },
    select: {
      name: true,
      admins: { select: { user: { select: { id: true, name: true, phone: true } } } },
    },
  });
  if (!store) notFound();

  const admins = store.admins.map((a) => a.user);

  return (
    <div className="mx-auto max-w-2xl space-y-8">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">{t.storeAdminsTitle(store.name)}</h1>
        <p className="text-sm text-gray-500">{t.storeAdminsDesc}</p>
      </div>

      <PromoteAdminForm storeId={storeId} t={clientT} />

      <div className="overflow-hidden rounded-lg border border-gray-200 bg-white">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-gray-200 bg-gray-50 text-gray-500">
            <tr>
              <th className="px-4 py-2 font-medium">{t.name}</th>
              <th className="px-4 py-2 font-medium">{t.phone}</th>
              <th className="px-4 py-2 font-medium"></th>
            </tr>
          </thead>
          <tbody>
            {admins.length === 0 && (
              <tr>
                <td colSpan={3} className="px-4 py-6 text-center text-gray-400">
                  {t.noAdminsYet}
                </td>
              </tr>
            )}
            {admins.map((admin) => (
              <tr key={admin.id} className="border-b border-gray-100 last:border-0">
                <td className="px-4 py-2 text-gray-900">{admin.name || "..."}</td>
                <td className="px-4 py-2 text-gray-500">{admin.phone}</td>
                <td className="px-4 py-2 text-right">
                  <RevokeAdminButton storeId={storeId} userId={admin.id} t={clientT} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div>
        <h2 className="mb-2 text-sm font-semibold text-gray-500">{t.dangerZone}</h2>
        <DeleteStoreButton
          storeId={storeId}
          storeName={store.name}
          confirmLabel={t.deleteStoreConfirmLabel(store.name)}
          t={clientT}
        />
      </div>
    </div>
  );
}
