// Bundles the sign-in pages' script (client/auth.ts) into public/assets/auth.js.
// `--watch` rebuilds on changes (npm run dev).
import { context, build, type BuildOptions } from "esbuild";

const options: BuildOptions = {
  entryPoints: ["client/auth.ts"],
  outfile: "public/assets/auth.js",
  bundle: true,
  minify: true,
  format: "iife",
  target: ["es2020", "safari15"],
  legalComments: "none",
  logLevel: "info",
};

async function main(): Promise<void> {
  if (process.argv.includes("--watch")) {
    const ctx = await context(options);
    await ctx.watch();
  } else {
    await build(options);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
