import { Timestamp } from "firebase-admin/firestore";
import { adminDb } from "@/lib/firebaseAdmin";
import { getTranslations, toClientDict } from "@/lib/l10n";
import { OrdersTable, type OrderRow } from "./_components/OrdersTable";

const WINDOW_DAYS = 90;

async function getStoreNames(): Promise<Record<string, string>> {
  const snap = await adminDb.collection("stores").select("name").get();
  return Object.fromEntries(snap.docs.map((doc) => [doc.id, doc.data().name as string]));
}

async function getOrders(storeNames: Record<string, string>): Promise<OrderRow[]> {
  const cutoff = Timestamp.fromMillis(Date.now() - WINDOW_DAYS * 24 * 60 * 60 * 1000);
  const snap = await adminDb
    .collection("orders")
    .where("createdAt", ">=", cutoff)
    .orderBy("createdAt", "desc")
    .select("storeId", "itemQuantity", "createdAt", "userPhone")
    .get();

  return snap.docs.map((doc) => {
    const data = doc.data();
    const createdAt = data.createdAt as Timestamp;
    return {
      storeId: data.storeId as string,
      storeName: storeNames[data.storeId as string] ?? data.storeId as string,
      userPhone: (data.userPhone as string) ?? "",
      itemQuantity: data.itemQuantity as number,
      date: createdAt.toDate().toISOString().slice(0, 10),
    };
  });
}

export default async function DashboardPage() {
  const t = await getTranslations();
  const storeNames = await getStoreNames();
  const orders = await getOrders(storeNames);

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
