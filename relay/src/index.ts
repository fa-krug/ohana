// The relay process (`npm start`, the image): checks the environment, then serves src/app.ts.
import { serve } from "@hono/node-server";
import pkg from "../package.json";
import { Http2ApnsClient } from "./apns";
import { createApp } from "./app";
import { ConfigError, loadConfig, type Config } from "./config";
import { Stats } from "./stats";

let config: Config;
try {
  config = loadConfig();
} catch (err) {
  if (!(err instanceof ConfigError)) throw err;
  console.error(`[relay] ${err.message}`);
  process.exit(1);
}

const apns = new Http2ApnsClient(config.apns);
const stats = new Stats();
const app = createApp({
  apns,
  secrets: config.secrets,
  topic: config.apns.topic,
  trustProxy: config.trustProxy,
  stats,
});

const hostname = process.env.HOST ?? "0.0.0.0";
const server = serve({ fetch: app.fetch, port: config.port, hostname }, (info) => {
  console.log(
    `[relay] ohana-relay ${pkg.version} listening on ${hostname}:${info.port} ` +
      `(topic ${config.apns.topic}${config.secrets.old ? ", RELAY_SECRET_OLD set" : ""}${config.trustProxy ? ", behind a proxy" : ""})`,
  );
});

setInterval(() => {
  const line = stats.flush();
  if (line) console.log(`[relay] last hour: ${line}`);
}, 60 * 60 * 1000).unref();

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    console.log(`[relay] ${signal}, stopping`);
    server.close(() => {
      apns.close();
      process.exit(0);
    });
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
