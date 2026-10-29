import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  turbopack: {
    root: __dirname,
  },
  // better-sqlite3 / argon2 / sharp are native modules and must not be bundled into the
  // server build — keep them external so the standalone server require()s them
  // from node_modules at runtime (sharp loads its platform's @img/sharp-* binary).
  serverExternalPackages: ["better-sqlite3", "argon2", "sharp"],
  experimental: {
    // Recipe photos are uploaded through a server action (up to 5 MB, see
    // lib/meals/images/config.ts); the default limit is 1 MB.
    serverActions: { bodySizeLimit: "6mb" },
  },
};

export default nextConfig;
