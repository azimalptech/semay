import { getTranslations, toClientDict } from "@/lib/l10n";
import { requireSuperAdmin } from "@/lib/session";
import { BroadcastForm } from "./_components/BroadcastForm";

export default async function BroadcastPage() {
  // Defense in depth — see dashboard/page.tsx's comment on why every
  // protected page re-checks this instead of trusting the layout alone.
  await requireSuperAdmin();
  const t = await getTranslations();

  return (
    <div className="mx-auto max-w-xl space-y-8">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">{t.broadcastTitle}</h1>
        <p className="text-sm text-gray-500">{t.broadcastDesc}</p>
      </div>

      <BroadcastForm t={toClientDict(t)} />
    </div>
  );
}
