// The business runs in one country, so the dashboard buckets orders by the
// Asia/Ashgabat calendar day. Pinned as an IANA zone — never the host's local
// zone — so the Next.js process and the viewer's browser agree on which day
// "today" is, and an order placed at 02:00 in Ashgabat (21:00Z the previous
// evening) lands under the day the shop actually saw it rather than the UTC
// day before.
export const BUSINESS_TIME_ZONE = "Asia/Ashgabat";

const dayFormat = new Intl.DateTimeFormat("en-CA", {
  timeZone: BUSINESS_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

/** "YYYY-MM-DD" of the instant in the business zone. Built from parts rather
 *  than the formatted string so the shape never depends on locale output. */
export function businessDay(at: Date): string {
  const parts = dayFormat.formatToParts(at);
  const part = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((p) => p.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

/** The business-zone day n days before now. Ashgabat has no DST, so shifting
 *  the instant by whole days is exactly n calendar days. */
export function businessDaysAgo(n: number): string {
  return businessDay(new Date(Date.now() - n * 24 * 60 * 60 * 1000));
}
