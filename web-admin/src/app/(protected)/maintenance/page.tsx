import { getTranslations } from "@/lib/l10n";
import { requireSuperAdmin } from "@/lib/session";
import { DuplicateCleanup } from "./_components/DuplicateCleanup";

export default async function MaintenancePage() {
  await requireSuperAdmin();
  const t = await getTranslations();

  return (
    <div className="mx-auto max-w-2xl space-y-8">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">{t.maintenance}</h1>
        <p className="text-sm text-gray-500">
          One-off account maintenance. Superadmin only.
        </p>
      </div>
      <DuplicateCleanup />
    </div>
  );
}
