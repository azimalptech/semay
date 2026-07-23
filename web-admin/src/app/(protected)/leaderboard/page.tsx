import { Timestamp } from "firebase-admin/firestore";
import { adminDb } from "@/lib/firebaseAdmin";
import { getTranslations, toClientDict } from "@/lib/l10n";
import { requireSuperAdmin } from "@/lib/session";
import { CampaignForm } from "./_components/CampaignForm";
import { StoreOrderForm } from "./_components/StoreOrderForm";

export default async function LeaderboardPage() {
  // Defense in depth — see dashboard/page.tsx's comment on why every
  // protected page re-checks this instead of trusting the layout alone.
  await requireSuperAdmin();
  const t = await getTranslations();

  const storesSnap = await adminDb
    .collection("stores")
    .where("active", "==", true)
    .select("name", "leaderboardOrder", "campaignStartAt", "campaignImageUrl")
    .get();
  const stores = storesSnap.docs
    .map((doc) => {
      const data = doc.data();
      const campaignStartAt = data.campaignStartAt as Timestamp | undefined;
      return {
        id: doc.id,
        name: (data.name as string) ?? "",
        order: (data.leaderboardOrder as number | undefined) ?? Number.MAX_SAFE_INTEGER,
        campaignStartAtMillis: campaignStartAt ? campaignStartAt.toMillis() : null,
        campaignImageUrl: (data.campaignImageUrl as string | null | undefined) ?? null,
      };
    })
    .sort((a, b) => a.order - b.order || a.name.localeCompare(b.name));

  return (
    <div className="mx-auto max-w-xl space-y-8">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">{t.leaderboardTitle}</h1>
      </div>

      <CampaignForm
        initialStores={stores.map(({ id, name, campaignStartAtMillis, campaignImageUrl }) => ({
          id,
          name,
          campaignStartAtMillis,
          campaignImageUrl,
        }))}
        t={toClientDict(t)}
      />
      <StoreOrderForm initialStores={stores.map(({ id, name }) => ({ id, name }))} t={toClientDict(t)} />
    </div>
  );
}
