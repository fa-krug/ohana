// The server process (`docker-entrypoint.sh web`, `npm run dev`): serves http/app.ts on PORT.
import { serve } from "@hono/node-server";
import { db, sqlite } from "../lib/db/client";
import { enabledModules, serverVersion } from "../lib/server-info";
import { createApp } from "./app";

const port = Number(process.env.PORT ?? 3000);
const hostname = process.env.HOST ?? "0.0.0.0";

const server = serve({ fetch: createApp({ db }).fetch, port, hostname }, (info) => {
  console.log(`[http] Ohana ${serverVersion()} listening on ${hostname}:${info.port} (modules: ${enabledModules().join(", ")})`);
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    console.log(`[http] ${signal}, stopping`);
    server.close(() => {
      sqlite.close();
      process.exit(0);
    });
    // Streams (assistant, recipe generation) may hold connections open: don't wait forever.
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
