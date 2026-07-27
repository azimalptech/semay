import { prisma } from "@/lib/db";
import { getTranslations, toClientDict } from "@/lib/l10n";
import { requireSuperAdmin } from "@/lib/session";
import { CampaignForm } from "./_components/CampaignForm";
import { StoreOrderForm } from "./_components/StoreOrderForm";

export default async function LeaderboardPage() {
  // Defense in depth — see dashboard/page.tsx's comment on why every
  // protected page re-checks this instead of trusting the layout alone.
  await requireSuperAdmin();
  const t = await getTranslations();

  const activeStores = await prisma.store.findMany({
    where: { active: true },
    select: {
      id: true,
      name: true,
      leaderboardOrder: true,
      campaignStartAt: true,
      campaignEndAt: true,
      campaignImageUrl: true,
    },
  });
  const stores = activeStores
    .map((s) => ({
      id: s.id,
      name: s.name,
      order: s.leaderboardOrder ?? Number.MAX_SAFE_INTEGER,
      campaignStartAtMillis: s.campaignStartAt ? s.campaignStartAt.getTime() : null,
      campaignEndAtMillis: s.campaignEndAt ? s.campaignEndAt.getTime() : null,
      campaignImageUrl: s.campaignImageUrl,
    }))
    .sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));

  return (
    <div className="mx-auto max-w-xl space-y-8">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">{t.leaderboardTitle}</h1>
      </div>

      <CampaignForm
        initialStores={stores.map(
          ({ id, name, campaignStartAtMillis, campaignEndAtMillis, campaignImageUrl }) => ({
            id,
            name,
            campaignStartAtMillis,
            campaignEndAtMillis,
            campaignImageUrl,
          }),
        )}
        t={toClientDict(t)}
      />
      <StoreOrderForm initialStores={stores.map(({ id, name }) => ({ id, name }))} t={toClientDict(t)} />
    </div>
  );
}
