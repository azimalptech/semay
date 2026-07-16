import { notFound } from "next/navigation";
import { adminDb } from "@/lib/firebaseAdmin";
import { getTranslations, toClientDict } from "@/lib/l10n";
import { PromoteAdminForm } from "./_components/PromoteAdminForm";
import { RevokeAdminButton } from "./_components/RevokeAdminButton";

interface AdminRow {
  uid: string;
  name: string;
  phone: string;
}

export default async function StoreAdminsPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id: storeId } = await params;
  const t = await getTranslations();
  const clientT = toClientDict(t);

  const storeSnap = await adminDb.collection("stores").doc(storeId).get();
  if (!storeSnap.exists) notFound();
  const store = storeSnap.data()!;

  const adminIds: string[] = store.adminIds ?? [];
  const adminDocs = adminIds.length
    ? await adminDb.getAll(...adminIds.map((uid) => adminDb.collection("users").doc(uid)))
    : [];
  const admins: AdminRow[] = adminDocs
    .filter((doc) => doc.exists)
    .map((doc) => ({
      uid: doc.id,
      name: (doc.data()?.name as string) ?? "...",
      phone: (doc.data()?.phone as string) ?? "",
    }));

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
              <tr key={admin.uid} className="border-b border-gray-100 last:border-0">
                <td className="px-4 py-2 text-gray-900">{admin.name}</td>
                <td className="px-4 py-2 text-gray-500">{admin.phone}</td>
                <td className="px-4 py-2 text-right">
                  <RevokeAdminButton storeId={storeId} userId={admin.uid} t={clientT} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
