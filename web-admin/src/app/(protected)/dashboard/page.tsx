import { prisma } from "@/lib/db";
import { getTranslations, toClientDict } from "@/lib/l10n";
import { requireSuperAdmin } from "@/lib/session";
import { OrdersTable, type OrderRow } from "./_components/OrdersTable";

// Fetch a full year so the client-side range presets (7 / 30 / 90 days, 1 year)
// and the manual date pickers all have data to filter over — the actual window
// shown is chosen in OrdersTable, defaulting to 90 days.
const WINDOW_DAYS = 365;

async function getStoreNames(): Promise<Record<string, string>> {
  const stores = await prisma.store.findMany({ select: { id: true, name: true } });
  return Object.fromEntries(stores.map((s) => [s.id, s.name]));
}

async function getOrders(): Promise<OrderRow[]> {
  const cutoff = new Date(Date.now() - WINDOW_DAYS * 24 * 60 * 60 * 1000);
  const orders = await prisma.order.findMany({
    where: { createdAt: { gte: cutoff } },
    orderBy: { createdAt: "desc" },
    select: {
      storeId: true,
      itemQuantity: true,
      createdAt: true,
      userPhone: true,
      store: { select: { name: true } },
    },
  });

  return orders.map((o) => ({
    storeId: o.storeId,
    storeName: o.store.name,
    userPhone: o.userPhone,
    itemQuantity: o.itemQuantity,
    date: o.createdAt.toISOString().slice(0, 10),
  }));
}

export default async function DashboardPage() {
  // Defense in depth — the (protected) layout already checks this, but
  // layouts don't re-run on client-side navigation between sibling pages,
  // so without a per-page check here a revoked session keeps working on
  // this page (which reads customer phone numbers) until the access token
  // itself expires. requireSuperAdmin is cache()-memoized, so this costs
  // nothing extra when the layout already ran it this request.
  await requireSuperAdmin();
  const t = await getTranslations();
  const [storeNames, orders] = await Promise.all([getStoreNames(), getOrders()]);

  return (
    <div className="mx-auto max-w-3xl space-y-8">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">{t.ordersReport}</h1>
        <p className="text-sm text-gray-500">{t.ordersReportDesc(WINDOW_DAYS)}</p>
      </div>

      <OrdersTable orders={orders} storeNames={storeNames} t={toClientDict(t)} />
    </div>
  );
}
