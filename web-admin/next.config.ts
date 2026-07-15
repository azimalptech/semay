import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Silences a Turbopack warning — a stray lockfile elsewhere on this machine
  // (outside the repo) was making it guess the workspace root incorrectly.
  turbopack: {
    root: __dirname,
  },
};

export default nextConfig;
