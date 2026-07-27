import { buildApp } from "./app.js";
import { config } from "./config.js";
import { disconnectDb } from "./db.js";

// buildApp() creates the media dir before mounting the static server.
const app = await buildApp();

async function start(): Promise<void> {
  try {
    await app.listen({ port: config.PORT, host: "0.0.0.0" });
  } catch (err) {
    app.log.error(err);
    await disconnectDb();
    process.exit(1);
  }
}

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, async () => {
    await app.close();
    await disconnectDb();
    process.exit(0);
  });
}

void start();
