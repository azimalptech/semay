import { EventEmitter } from "node:events";

// In-process pub-sub for v1 (single Node process — see docs/07_MIGRATION.md /
// the approved plan). Deliberately behind this narrow publish/subscribe seam
// so a later Redis/cluster swap only touches this file, not every call site.
const emitter = new EventEmitter();
emitter.setMaxListeners(0); // unbounded — one listener per subscribed WS connection

export type RealtimeEvent =
  | { type: "snapshot"; data: unknown }
  | { type: "upsert"; data: unknown }
  | { type: "remove"; id: string };

export function publish(channel: string, event: RealtimeEvent): void {
  emitter.emit(channel, event);
}

export function subscribe(channel: string, listener: (event: RealtimeEvent) => void): () => void {
  emitter.on(channel, listener);
  return () => emitter.off(channel, listener);
}
