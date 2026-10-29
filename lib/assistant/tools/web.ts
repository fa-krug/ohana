// The web: search (Tavily or Brave, with the family's key) and reading pages. Every URL is
// checked against private addresses (net.ts), also after redirects.

import { HttpError } from "@/lib/api/http";
import { checkUrl, htmlToText, readLimited, safeFetch } from "../net";
import { MAX_PAGE_TEXT, type Tool } from "./common";

export const webTools: Record<string, Tool> = {
  web_search: {
    needsSearch: true,
    spec: {
      name: "web_search",
      description:
        "Searches the web. Returns titles, URLs and snippets; read promising results with fetch_page before relying on them.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string" },
          count: { type: "integer", description: "Results, default 5, at most 10" },
        },
        required: ["query"],
      },
    },
    async run(args, { net, search, signal }) {
      if (!search) throw new HttpError(400, "Web search isn't set up");
      const query = String(args.query ?? "").trim().slice(0, 400);
      if (!query) throw new HttpError(400, "query is required");
      const count = Math.min(10, Math.max(1, Number(args.count) || 5));
      let results: { title: string; url: string; snippet: string }[];
      if (search.provider === "tavily") {
        const res = await safeFetch("https://api.tavily.com/search", {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${search.key}` },
          body: JSON.stringify({ api_key: search.key, query, max_results: count }),
          signal,
        }, { ...net, allowPrivate: false });
        if (!res.ok) throw new HttpError(502, `Search failed: ${res.status}`);
        const data = JSON.parse(await readLimited(res, 1_000_000));
        results = (data.results ?? []).map((r: Record<string, string>) => ({
          title: r.title ?? "",
          url: r.url ?? "",
          snippet: (r.content ?? "").slice(0, 500),
        }));
      } else {
        const url = `https://api.search.brave.com/res/v1/web/search?count=${count}&q=${
          encodeURIComponent(query)
        }`;
        const res = await safeFetch(url, {
          headers: { accept: "application/json", "x-subscription-token": search.key },
          signal,
        }, { ...net, allowPrivate: false });
        if (!res.ok) throw new HttpError(502, `Search failed: ${res.status}`);
        const data = JSON.parse(await readLimited(res, 1_000_000));
        results = (data.web?.results ?? []).map((r: Record<string, string>) => ({
          title: r.title ?? "",
          url: r.url ?? "",
          snippet: (r.description ?? "").replace(/<[^>]+>/g, "").slice(0, 500),
        }));
      }
      return { result: { query, results: results.slice(0, count) }, summary: query };
    },
  },

  fetch_page: {
    spec: {
      name: "fetch_page",
      description: "Reads a web page (http or https) and returns its title and text.",
      parameters: {
        type: "object",
        properties: { url: { type: "string" } },
        required: ["url"],
      },
    },
    async run(args, { net, signal }) {
      const url = (await checkUrl(String(args.url ?? ""), net)).href;
      const res = await safeFetch(url, {
        headers: {
          accept: "text/html,text/plain,application/json;q=0.9,*/*;q=0.5",
          "user-agent": "FamilyPlanner/1.0 (+https://family-planner.fa-krug.de)",
        },
        signal,
        timeoutMs: 10000,
      }, net);
      if (!res.ok) throw new HttpError(502, `The page answered ${res.status}`);
      const type = res.headers.get("content-type") ?? "";
      if (!/text\/|json|xml/.test(type)) {
        await res.body?.cancel();
        throw new HttpError(415, `Can't read ${type.split(";")[0] || "this kind of file"}`);
      }
      const raw = await readLimited(res, 2_000_000);
      const { title, text } = type.includes("html") ? htmlToText(raw) : { title: "", text: raw };
      return {
        result: {
          url: res.url || url,
          title,
          text: text.slice(0, MAX_PAGE_TEXT),
          truncated: text.length > MAX_PAGE_TEXT,
        },
        summary: new URL(url).hostname,
      };
    },
  },
};
