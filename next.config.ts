import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  turbopack: {
    root: __dirname,
  },
  // better-sqlite3 / argon2 are native modules and must not be bundled into the
  // server build — keep them external so the standalone server require()s them
  // from node_modules at runtime.
  serverExternalPackages: ["better-sqlite3", "argon2"],
};

export default nextConfig;
