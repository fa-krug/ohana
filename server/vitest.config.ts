import { configDefaults, defineConfig } from "vitest/config";
import { resolve } from "node:path";

export default defineConfig({
  resolve: {
    alias: {
      "@": resolve(__dirname, "."),
    },
  },
  test: {
    globals: true,
    environment: "node",
    // `next build` emits a traced copy of the source (incl. *.test.* files) under
    // .next/standalone; without this exclude vitest discovers every test twice.
    exclude: [...configDefaults.exclude, "**/.next/**"],
  },
});
