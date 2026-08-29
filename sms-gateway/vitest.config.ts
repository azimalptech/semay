import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    setupFiles: ["./tests/setup.ts"],
    // Dispatch is deliberately serialised in-process, and the tests assert on
    // that ordering, so they must not run concurrently against one database.
    fileParallelism: false,
    testTimeout: 20000,
  },
});
