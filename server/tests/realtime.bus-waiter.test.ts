import { createServer, type AddressInfo, type Server, type Socket } from "node:net";

import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

// Concurrency contract for the ONE ioredis subscriber connection the bus owns.
//
// awaitSubscriberUsable() used to attach its own `once(subscriber,'ready')` +
// `once(subscriber,'close')` per call, and node's `events.once` attaches an
// 'error' listener alongside each — ~6 listeners on that single client per
// in-flight subscribe, for up to SUBSCRIBE_TIMEOUT_MS. The branch is entered
// exactly when Redis is SLOW rather than refused (a firewall DROP, a hung
// box), which is the degradation the bus exists to survive. Reproduced before
// the fix on a booted server (CLAUDE.md rule 9) with ONE socket subscribing 12
// channels in a burst against a blackholed REDIS_URL:
//
//   (node:26020) MaxListenersExceededWarning: Possible EventEmitter memory
//     leak detected. 11 error listeners added to [Commander]. …
//   (node:26020) … 11 ready listeners added to [Commander]. …
//   (node:26020) … 11 close listeners added to [Commander]. …
//
// — log noise in the exact incident an operator is reading, and, because
// EventEmitter add/remove is a push + indexOf/splice, O(N^2) on one emitter at
// the scale docs/08 §2 plans for (thousands of phones re-subscribing at once).
//
// The failure is reproduced here with a TCP server that ACCEPTS and never
// speaks RESP: ioredis connects, waits for a reply that never comes, and sits
// in the non-ready state that opens the branch. A refused port would fail
// instantly and hide it.

const BURST = 24;

/** Accepts every connection and answers nothing — a Redis that is reachable
 * and hung, which is what keeps `subscriber.status` off "ready" without ever
 * erroring fast. */
class BlackholeRedis {
  private server: Server | undefined;
  private readonly sockets = new Set<Socket>();
  port = 0;

  async start(): Promise<void> {
    const server = createServer((socket) => {
      this.sockets.add(socket);
      socket.on("error", () => this.sockets.delete(socket));
      socket.on("close", () => this.sockets.delete(socket));
      // Deliberately no reply, ever.
    });
    this.server = server;
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => resolve());
    });
    this.port = (server.address() as AddressInfo).port;
  }

  async stop(): Promise<void> {
    for (const s of this.sockets) s.destroy();
    this.sockets.clear();
    const server = this.server;
    this.server = undefined;
    await new Promise<void>((resolve) => (server ? server.close(() => resolve()) : resolve()));
  }
}

describe("bus: many concurrent subscribes against a hung Redis", () => {
  const blackhole = new BlackholeRedis();
  let bus: typeof import("../src/realtime/bus.js");
  const warnings: Error[] = [];
  const onWarning = (w: Error): void => {
    warnings.push(w);
  };

  beforeAll(async () => {
    await blackhole.start();
    process.on("warning", onWarning);
    vi.resetModules();
    vi.stubEnv("REDIS_URL", `redis://127.0.0.1:${blackhole.port}`);
    bus = await import("../src/realtime/bus.js");
  });

  afterAll(async () => {
    process.off("warning", onWarning);
    await bus.closeBus();
    await blackhole.stop();
    // closeBus bounds its QUIT (CLOSE_QUIT_TIMEOUT_MS) precisely so a hung
    // Redis cannot hold a shutdown open; without that this hook timed out.
    vi.unstubAllEnvs();
    vi.resetModules();
  });

  /** Runs `n` distinct first-listener subscribes at once and reports the
   * listener counts sampled WHILE they are all outstanding — the moment the
   * old code held ~6 * n of them on one client. */
  async function burst(n: number, tag: string): Promise<Record<string, number>> {
    const channels = Array.from({ length: n }, (_, i) => `post:${tag}-${i}`);
    const inFlight = channels.map((c) => bus.subscribe(c, () => {}));
    await new Promise((r) => setTimeout(r, 250));
    const during = bus.subscriberListenerCounts();
    const releases = await Promise.all(inFlight);
    // Bounded, and every one of them answered: the caller's snapshot goes out
    // regardless of Redis, which is the whole point of the bound. None reached
    // Redis, so all are cross-process gaps until the next 'ready' re-issues
    // them (resubscribeAll).
    expect(releases).toHaveLength(n);
    expect(bus.busHealth().pendingChannels).toBe(n);
    for (const release of releases) release();
    expect(bus.busHealth().pendingChannels).toBe(0);
    return during;
  }

  it(`holds the same listener set for 2 and for ${BURST} in-flight subscribes, and warns about none`, async () => {
    // The connection is up but not ready — the branch under test.
    expect(bus.busHealth()).toMatchObject({ mode: "redis", ready: false });
    expect(bus.subscriberListenerCounts().ready).toBeGreaterThan(0);

    // Growth WITH CONCURRENCY is the defect, so the two are compared to each
    // other rather than to an absolute number: ioredis attaches listeners of
    // its own as a connection moves through its states, and pinning those
    // would pin the library, not this module. Under the old code these two
    // samples differed by 6 * (BURST - 2) = 132.
    const small = await burst(2, "waiter-small");
    const large = await burst(BURST, `waiter-large`);
    for (const event of ["ready", "close", "error"] as const) {
      expect(large[event], `${event} listeners at ${BURST} vs at 2`).toBe(small[event]);
    }

    // The decisive one: node prints MaxListenersExceededWarning past 10
    // listeners on one emitter, so the old code tripped it at two concurrent
    // subscribes — reproduced on a booted server, three lines, in the log an
    // operator reads during the incident.
    const exceeded = warnings.filter((w) => w.name === "MaxListenersExceededWarning");
    expect(exceeded.map((w) => w.message)).toEqual([]);
  }, 30_000);

  it("local delivery is untouched while the waiter is shared", async () => {
    const seen: string[] = [];
    const release = await bus.subscribe("post:waiter-local", (e) => {
      seen.push(e.type);
    });
    bus.publish("post:waiter-local", { type: "upsert", data: { id: "x" } });
    expect(seen).toEqual(["upsert"]);
    release();
  }, 15_000);
});
