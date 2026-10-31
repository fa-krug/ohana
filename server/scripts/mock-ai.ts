// Serves the scripted stand-in for an OpenAI-compatible API (lib/test/mock-ai.ts) on
// http://localhost:<port>/v1, to try the assistant without a key:
//   npm run mock-ai -- 4011
// then run the app and the worker with AI_ALLOW_PRIVATE_ENDPOINT=1 and set the API URL to
// http://localhost:4011/v1 (model "mock-large") in Settings → AI.
import { createServer } from "node:http";
import { Readable } from "node:stream";
import { mockAi } from "../lib/test/mock-ai";

const port = Number(process.argv[2] ?? process.env.PORT ?? 4011);

createServer(async (req, res) => {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c as Buffer);
  const controller = new AbortController();
  req.on("close", () => controller.abort());
  const request = new Request(`http://localhost:${port}${req.url}`, {
    method: req.method,
    headers: req.headers as Record<string, string>,
    body: req.method === "GET" || req.method === "HEAD" ? undefined : Buffer.concat(chunks),
    signal: controller.signal,
  });
  try {
    const answer = await mockAi(request);
    res.writeHead(answer.status, Object.fromEntries(answer.headers));
    if (answer.body) Readable.fromWeb(answer.body as never).pipe(res);
    else res.end();
  } catch (err) {
    res.writeHead(500).end(String(err));
  }
}).listen(port, () => console.log(`[mock-ai] http://localhost:${port}/v1`));
