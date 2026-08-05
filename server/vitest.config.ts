import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    setupFiles: ["./tests/setup.ts"],
    // Backstop for fixture rows whose per-file afterAll never ran (setup threw,
    // worker killed, run interrupted) — see tests/globalTeardown.ts.
    globalSetup: ["./tests/globalTeardown.ts"],
    testTimeout: 15000,
  },
});
