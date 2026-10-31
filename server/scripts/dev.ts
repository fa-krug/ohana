// `npm run dev`: the server, restarted on changes (tsx watch), and the pages' script, rebuilt
// on changes (esbuild). Ctrl+C stops both.
import { spawn } from "node:child_process";

const tsx = "./node_modules/.bin/tsx";
const children = [
  spawn(tsx, ["scripts/build-client.ts", "--watch"], { stdio: "inherit" }),
  spawn(tsx, ["watch", "--clear-screen=false", "http/index.ts"], { stdio: "inherit" }),
];
const stop = () => {
  for (const child of children) child.kill("SIGTERM");
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
for (const child of children) child.on("exit", (code) => {
  stop();
  process.exitCode = code ?? 0;
});
