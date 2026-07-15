import { Timestamp } from "firebase-admin/firestore";
import { adminDb } from "@/lib/firebaseAdmin";

const WINDOW_DAYS = 90;

interface OrderRow {
  storeId: string;
  itemQuantity: number;
  day: string; // YYYY-MM-DD
}

async function getOrders(): Promise<OrderRow[]> {
  const cutoff = Timestamp.fromMillis(Date.now() - WINDOW_DAYS * 24 * 60 * 60 * 1000);
  const snap = await adminDb
    .collection("orders")
    .where("createdAt", ">=", cutoff)
    .select("storeId", "itemQuantity", "createdAt")
    .get();

  return snap.docs.map((doc) => {
    const data = doc.data();
    const createdAt = data.createdAt as Timestamp;
    return {
      storeId: data.storeId as string,
      itemQuantity: data.itemQuantity as number,
      day: createdAt.toDate().toISOString().slice(0, 10),
    };
  });
}

async function getStoreNames(): Promise<Record<string, string>> {
  const snap = await adminDb.collection("stores").select("name").get();
  return Object.fromEntries(snap.docs.map((doc) => [doc.id, doc.data().name as string]));
}

export default async function DashboardPage() {
  const [orders, storeNames] = await Promise.all([getOrders(), getStoreNames()]);
  const storeIds = Object.keys(storeNames).sort((a, b) =>
    storeNames[a].localeCompare(storeNames[b])
  );
  const showPerStore = storeIds.length > 1;

  const byDay = new Map<string, number>();
  const byDayStore = new Map<string, Map<string, number>>();

  for (const order of orders) {
    byDay.set(order.day, (byDay.get(order.day) ?? 0) + order.itemQuantity);
    if (!byDayStore.has(order.day)) byDayStore.set(order.day, new Map());
    const dayMap = byDayStore.get(order.day)!;
    dayMap.set(order.storeId, (dayMap.get(order.storeId) ?? 0) + order.itemQuantity);
  }

  const days = Array.from(byDay.keys()).sort((a, b) => b.localeCompare(a));

  return (
    <div className="mx-auto max-w-3xl space-y-8">
      <div>
        <h1 className="text-lg font-semibold text-gray-900">Orders report</h1>
        <p className="text-sm text-gray-500">
          Read-only. Total item quantity ordered, last {WINDOW_DAYS} days. Every order counts —
          there is no status or approval step.
        </p>
      </div>

      <div className="overflow-hidden rounded-lg border border-gray-200 bg-white">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-gray-200 bg-gray-50 text-gray-500">
            <tr>
              <th className="px-4 py-2 font-medium">Day</th>
              <th className="px-4 py-2 font-medium">Total items</th>
              {showPerStore &&
                storeIds.map((id) => (
                  <th key={id} className="px-4 py-2 font-medium">
                    {storeNames[id]}
                  </th>
                ))}
            </tr>
          </thead>
          <tbody>
            {days.length === 0 && (
              <tr>
                <td
                  colSpan={showPerStore ? 2 + storeIds.length : 2}
                  className="px-4 py-6 text-center text-gray-400"
                >
                  No orders in the last {WINDOW_DAYS} days.
                </td>
              </tr>
            )}
            {days.map((day) => (
              <tr key={day} className="border-b border-gray-100 last:border-0">
                <td className="px-4 py-2 text-gray-900">{day}</td>
                <td className="px-4 py-2 font-medium text-gray-900">{byDay.get(day)}</td>
                {showPerStore &&
                  storeIds.map((id) => (
                    <td key={id} className="px-4 py-2 text-gray-500">
                      {byDayStore.get(day)?.get(id) ?? 0}
                    </td>
                  ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
