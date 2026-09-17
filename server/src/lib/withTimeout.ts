/** Rejects with "`what` timed out after N ms" when `promise` has not settled in
 * time. The underlying operation keeps running — a caller that installs state
 * on success must check whether it was abandoned before using the late result
 * (see realtime/gateway.ts).
 *
 * Exists because a Redis command with no reply and a snapshot query that never
 * returns both used to hang the realtime subscribe path forever, with the
 * client left waiting on a snapshot that would never come. */
export function withTimeout<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${what} timed out after ${ms} ms`)), ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (err: unknown) => {
        clearTimeout(timer);
        reject(err);
      }
    );
  });
}
