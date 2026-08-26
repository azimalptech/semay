// A simulated sender handset, for testing the relay without a phone.
//
//   node scripts/fake-device.mjs --token <device-token> [--url ws://127.0.0.1:8081/device/ws]
//   node scripts/fake-device.mjs --token <t> --fail      # report every job Failed
//   node scripts/fake-device.mjs --token <t> --silent    # accept jobs, never report
//
// --fail and --silent exist to exercise the two failure paths that are hard to
// reproduce with real hardware: a SIM that rejects everything (no balance,
// blocked by the carrier) and a handset that goes away mid-send. Both should
// end with the message reassigned to another SIM, then Failed after
// MAX_ATTEMPTS — never stuck Assigned forever.
import WebSocket from "ws";

const argv = process.argv.slice(2);
const has = (f) => argv.includes(`--${f}`);
const valueOf = (f) => {
  const i = argv.indexOf(`--${f}`);
  return i === -1 ? undefined : argv[i + 1];
};

const token = valueOf("token");
if (!token) {
  console.error("\n  Usage: node scripts/fake-device.mjs --token <device-token> [--url ws://…]\n");
  process.exit(1);
}
const url = valueOf("url") ?? "ws://127.0.0.1:8081/device/ws";
const slots = Number(valueOf("sims") ?? 2);

const ws = new WebSocket(url, { headers: { Authorization: `Bearer ${token}` } });

ws.on("open", () => {
  console.log(`[device] connected to ${url}`);
  const sims = Array.from({ length: slots }, (_, i) => ({
    slotIndex: i,
    subscriptionId: 10 + i,
    carrierName: "TMCELL",
    phoneNumber: "",
  }));
  ws.send(JSON.stringify({ type: "hello", sims }));
  console.log(`[device] announced ${slots} SIM(s)`);
});

ws.on("message", (raw) => {
  let msg;
  try {
    msg = JSON.parse(raw.toString());
  } catch {
    return;
  }

  if (msg.type === "ping") {
    ws.send(JSON.stringify({ type: "pong" }));
    return;
  }

  if (msg.type === "send") {
    console.log(
      `[device] JOB id=${msg.id} sub=${msg.subscriptionId} to=${(msg.phoneNumbers ?? []).join(",")} text=${JSON.stringify(msg.text)}`
    );
    if (has("silent")) {
      console.log("[device] --silent: not reporting (relay should reclaim it)");
      return;
    }
    const state = has("fail") ? "Failed" : "Sent";
    setTimeout(() => {
      ws.send(
        JSON.stringify({
          type: "report",
          id: msg.id,
          state,
          ...(has("fail") ? { error: "simulated radio failure" } : {}),
        })
      );
      console.log(`[device] reported ${state}`);
      if (state === "Sent") {
        setTimeout(() => {
          ws.send(JSON.stringify({ type: "report", id: msg.id, state: "Delivered" }));
          console.log("[device] reported Delivered");
        }, 400);
      }
    }, 300);
  }
});

ws.on("close", (code, reason) => {
  console.log(`[device] closed code=${code} reason=${reason?.toString() || "(none)"}`);
  process.exit(code === 4401 ? 1 : 0);
});
ws.on("error", (e) => console.log(`[device] error: ${e.message}`));
