// HTTP helpers and input checks shared by the family API modules (ported from family-planner's
// _shared/http.ts).

import type { Lang } from "@/lib/i18n/config";

export const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
  "access-control-allow-headers": "content-type, authorization",
  "access-control-max-age": "86400",
  "access-control-expose-headers": "retry-after",
};

// Pages and files that carry a secret id: never cache or index them.
export const NO_STORE = { "cache-control": "no-store", "x-robots-tag": "noindex" };

const LANGS: Lang[] = ["en", "de"];
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

/** An error that becomes `{ "error": message }` with its status. */
export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
    public headers: Record<string, string> = {},
  ) {
    super(message);
    this.name = "HttpError";
  }
}

export function randomToken(length = 20): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return [...bytes].map((b) => ALPHABET[b % ALPHABET.length]).join("");
}

export function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, ...headers, "content-type": "application/json; charset=utf-8" },
  });
}

export async function readBody(req: Request): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (!text.trim()) return {};
  try {
    const body = JSON.parse(text);
    if (body && typeof body === "object") return body;
  } catch {
    // fall through
  }
  throw new HttpError(400, "Body must be a JSON object");
}

export function objectOf(raw: unknown, what: string): Record<string, unknown> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new HttpError(400, `${what} must be an object`);
  }
  return raw as Record<string, unknown>;
}

export function cleanName(v: unknown, field = "name"): string {
  if (typeof v !== "string" || !v.trim()) throw new HttpError(400, `${field} is required`);
  const s = v.trim();
  if (s.length > 80) throw new HttpError(400, `${field} is too long (max. 80)`);
  return s;
}

export function cleanYear(v: unknown, field = "year"): number {
  const s = typeof v === "number" ? String(v) : v;
  if (typeof s !== "string" || !/^\d{4}$/.test(s)) {
    throw new HttpError(400, `${field} must be YYYY`);
  }
  return Number(s);
}

export function currentYear(now = new Date()): number {
  return now.getUTCFullYear();
}

export function cleanLang(v: unknown): Lang {
  if (v === undefined) return "en";
  if (!LANGS.includes(v as Lang)) throw new HttpError(400, "lang must be en or de");
  return v as Lang;
}

export function slug(name: string): string {
  return (
    name
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[̀-ͯ]/g, "")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 32) || "type"
  );
}
