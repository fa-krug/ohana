// Outgoing requests on behalf of a family: to their AI endpoint, to a search API and to web
// pages the assistant reads. Every URL comes from a user or a model, so private, loopback and
// link-local addresses are refused (also after redirects and, where the runtime can resolve
// names, after DNS), and responses are size- and time-limited.

import { lookup } from "node:dns/promises";
import { HttpError } from "@/lib/api/http";

export type Fetch = typeof fetch;

export interface NetOptions {
  fetch: Fetch;
  /** Local development and tests may reach localhost (a local model, a mock). */
  allowPrivate?: boolean;
  /** Resolves a host name to addresses; default: the system resolver (node:dns). */
  resolve?: (host: string) => Promise<string[]>;
}

const MAX_REDIRECTS = 3;

function ipv4Private(ip: string): boolean {
  const p = ip.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return true;
  const [a, b] = p;
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
    (a === 100 && b >= 64 && b <= 127) || // carrier-grade NAT
    (a === 192 && b === 0) || (a === 198 && (b === 18 || b === 19)) || a >= 224;
}

function ipv6Private(ip: string): boolean {
  const s = ip.toLowerCase().replace(/^\[|\]$/g, "");
  if (s === "::" || s === "::1") return true;
  const v4 = /::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(s);
  if (v4) return ipv4Private(v4[1]);
  return /^(fc|fd|fe8|fe9|fea|feb|ff)/.test(s) || s.startsWith("64:ff9b:") ||
    s.startsWith("2001:db8");
}

/** Whether an address (or a host name that is one) is private, loopback, link-local … */
export function isPrivateAddress(host: string): boolean {
  const h = host.toLowerCase().replace(/\.$/, "");
  if (/^\d+\.\d+\.\d+\.\d+$/.test(h)) return ipv4Private(h);
  if (h.includes(":")) return ipv6Private(h);
  // Numeric forms browsers accept (2130706433, 0x7f.1) are refused outright.
  if (/^[\d.x]+$/i.test(h)) return true;
  return h === "localhost" || h.endsWith(".localhost") || h.endsWith(".local") ||
    h.endsWith(".internal") || h.endsWith(".lan") || h === "metadata.google.internal" ||
    !h.includes(".");
}

async function defaultResolve(host: string): Promise<string[]> {
  const found = await lookup(host, { all: true, verbatim: true });
  return found.map((a) => a.address);
}

/** Throws unless the URL is http(s) to a public host. */
export async function checkUrl(raw: string, opts: NetOptions): Promise<URL> {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new HttpError(400, `Not a valid URL: ${raw.slice(0, 200)}`);
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new HttpError(400, "Only http and https URLs are allowed");
  }
  if (url.username || url.password) {
    throw new HttpError(400, "URLs with credentials aren't allowed");
  }
  if (opts.allowPrivate) return url;
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (isPrivateAddress(host)) throw new HttpError(400, `Private addresses aren't allowed: ${host}`);
  if (!/^[\d.:]+$/.test(host)) {
    let addresses: string[] = [];
    try {
      addresses = await (opts.resolve ?? defaultResolve)(host);
    } catch {
      // A name that can't be resolved fails at fetch time anyway.
    }
    if (addresses.some(isPrivateAddress)) {
      throw new HttpError(400, `${host} points to a private address`);
    }
  }
  return url;
}

/** fetch() with the URL check on every hop, a timeout and the caller's abort signal. */
export async function safeFetch(
  raw: string,
  init: RequestInit & { timeoutMs?: number },
  opts: NetOptions,
): Promise<Response> {
  const timeout = AbortSignal.timeout(init.timeoutMs ?? 15000);
  const signal = init.signal ? AbortSignal.any([init.signal, timeout]) : timeout;
  let url = (await checkUrl(raw, opts)).href;
  for (let hop = 0;; hop++) {
    const res = await opts.fetch(url, { ...init, signal, redirect: "manual" });
    const location = res.headers.get("location");
    if (res.status >= 300 && res.status < 400 && location) {
      await res.body?.cancel();
      if (hop >= MAX_REDIRECTS) throw new HttpError(502, "Too many redirects");
      url = (await checkUrl(new URL(location, url).href, opts)).href;
      continue;
    }
    return res;
  }
}

/** Reads at most `max` bytes of a response as text. */
export async function readLimited(res: Response, max: number): Promise<string> {
  if (!res.body) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (size < max) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    size += value.length;
  }
  await reader.cancel().catch(() => {});
  const all = new Uint8Array(Math.min(size, max));
  let offset = 0;
  for (const c of chunks) {
    const part = c.subarray(0, Math.min(c.length, all.length - offset));
    all.set(part, offset);
    offset += part.length;
    if (offset >= all.length) break;
  }
  return new TextDecoder().decode(all);
}

const ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  auml: "ä",
  ouml: "ö",
  uuml: "ü",
  Auml: "Ä",
  Ouml: "Ö",
  Uuml: "Ü",
  szlig: "ß",
  euro: "€",
  ndash: "–",
  mdash: "—",
  hellip: "…",
};

function decodeEntities(s: string): string {
  return s.replace(/&(#x[\da-f]+|#\d+|[a-z]+);/gi, (m, e: string) => {
    if (e[0] === "#") {
      const code = e[1].toLowerCase() === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return code > 0 && code < 0x110000 ? String.fromCodePoint(code) : m;
    }
    return ENTITIES[e] ?? m;
  });
}

/** The readable text of an HTML page (no scripts, styles or navigation) and its title. */
export function htmlToText(html: string): { title: string; text: string } {
  const title = decodeEntities(/<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1] ?? "").trim();
  const body = html
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(
      /<(head|title|script|style|noscript|svg|template|nav|footer|header|form|iframe)\b[\s\S]*?<\/\1>/gi,
      " ",
    )
    .replace(/<(br|\/p|\/div|\/ul|\/ol|\/tr|\/h[1-6]|\/section|\/article|\/table)\b[^>]*>/gi, "\n")
    .replace(/<li\b[^>]*>/gi, "\n- ")
    .replace(/<\/t[dh]>/gi, " | ")
    .replace(/<[^>]+>/g, " ");
  const text = decodeEntities(body)
    .replace(/[ \t\f\v ]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return { title, text };
}
