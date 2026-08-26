import type { WebSocket } from "ws";

/// Live device sockets, keyed by device id.
///
/// In-process on purpose, and the reason this relay MUST run as a single
/// process: a handset's socket lives on exactly one node, so a second node
/// would consider every device it does not personally hold to be offline and
/// would happily assign work to nobody. If this ever needs to scale out, the
/// registry and the dispatch lock move to Redis together — not one without the
/// other. Throughput here is bounded by SIM cards, not CPU, so that day is far
/// off: one process can saturate hundreds of handsets.
const sockets = new Map<string, WebSocket>();

export function bind(deviceId: string, socket: WebSocket): void {
  // A reconnect before the old socket's close event fires would otherwise
  // leave the stale entry to win. Close the old one explicitly.
  const previous = sockets.get(deviceId);
  if (previous && previous !== socket) {
    try {
      previous.close(4000, "replaced by a newer connection");
    } catch {
      // Already dead — nothing to do.
    }
  }
  sockets.set(deviceId, socket);
}

export function unbind(deviceId: string, socket: WebSocket): void {
  // Only clear if the socket closing is the one currently registered, or a
  // late close from a replaced connection would evict the live one.
  if (sockets.get(deviceId) === socket) sockets.delete(deviceId);
}

export function isOnline(deviceId: string): boolean {
  return sockets.has(deviceId);
}

export function onlineDeviceIds(): string[] {
  return [...sockets.keys()];
}

/** Returns false if the device is not connected or the write failed, so the
 * caller can put the message straight back rather than leaving it Assigned to
 * a handset that never received it. */
export function send(deviceId: string, payload: unknown): boolean {
  const socket = sockets.get(deviceId);
  if (!socket) return false;
  try {
    socket.send(JSON.stringify(payload));
    return true;
  } catch {
    return false;
  }
}
