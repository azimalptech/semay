import { prisma } from "@/lib/db";
import { getTranslations, toClientDict } from "@/lib/l10n";
import { requireSuperAdmin } from "@/lib/session";
import { RequestActions } from "./_components/RequestActions";

interface RequestRow {
  id: string;
  storeName: string;
  message: string;
  createdAtMillis: number | null;
}

async function getPendingRequests(): Promise<RequestRow[]> {
  const requests = await prisma.notificationRequest.findMany({
    where: { status: "pending" },
    orderBy: { createdAt: "asc" },
  });
  return requests.map((r) => ({
    id: r.id,
    storeName: r.storeName,
    message: r.message,
    createdAtMillis: r.createdAt.getTime(),
  }));
}

export default async function NotificationRequestsPage() {
  // Defense in depth — see dashboard/page.tsx's comment; layouts don't
  // re-run on client-side navigation, so per-page checks are what actually
  // makes session revocation take effect promptly on this page.
  await requireSuperAdmin();
  const t = await getTranslations();
  const requests = await getPendingRequests();

  return (
    <div className="mx-auto max-w-2xl space-y-8">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">{t.notificationRequestsTitle}</h1>
        <p className="text-sm text-gray-500">{t.notificationRequestsDesc}</p>
      </div>

      {requests.length === 0 ? (
        <p className="text-sm text-gray-400">{t.noPendingRequests}</p>
      ) : (
        <div className="space-y-4">
          {requests.map((req) => (
            <div key={req.id} className="rounded-lg border border-gray-200 bg-white p-6">
              <p className="text-sm font-medium text-gray-900">
                {t.requestedBy}: {req.storeName}
              </p>
              <p className="mt-2 text-sm text-gray-700">{req.message}</p>
              <div className="mt-4">
                <RequestActions requestId={req.id} t={toClientDict(t)} />
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
