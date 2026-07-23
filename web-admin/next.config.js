/** @type {import('next').NextConfig} */
const nextConfig = {
  experimental: {
    // Prevent Turbopack from creating symlinks for firebase-admin, which breaks in Cloud Run
    optimizePackageImports: ["firebase-admin"],
  },
};

module.exports = nextConfig;
