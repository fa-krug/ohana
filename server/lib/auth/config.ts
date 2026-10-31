export const SESSION_COOKIE = "ohana_session";
export const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days
export const SETUP_TTL_MS = 7 * 24 * 60 * 60 * 1000; // setup links: 7 days
export const CEREMONY_COOKIE = "ohana_ceremony";
export const CEREMONY_TTL_MS = 5 * 60 * 1000; // 5 minutes

const DEV_SECRET = "dev-insecure-secret-change-me";

function splitEnv(raw: string | undefined, fallback: string[]): string[] {
  if (!raw) return fallback;
  const parts = raw.split(",").map((p) => p.trim()).filter(Boolean);
  return parts.length > 0 ? parts : fallback;
}

export function getAuthSecret(): string {
  const secret = process.env.AUTH_SECRET;
  if (secret) return secret;
  if (process.env.NODE_ENV === "production") {
    throw new Error("AUTH_SECRET must be set in production");
  }
  return DEV_SECRET;
}

export function getRpName(): string {
  return process.env.WEBAUTHN_RP_NAME ?? "Ohana";
}

/** APP_URL without a trailing slash, or null when it isn't set. */
function appUrlEnv(): string | null {
  const raw = process.env.APP_URL?.trim();
  return raw ? raw.replace(/\/+$/, "") : null;
}

/** WEBAUTHN_RP_ID (comma list), else APP_URL's host name, else localhost. */
export function getAllowedRpIds(): string[] {
  const app = appUrlEnv();
  let fallback = ["localhost"];
  if (app) {
    try {
      fallback = [new URL(app).hostname];
    } catch {
      // an invalid APP_URL: keep localhost
    }
  }
  return splitEnv(process.env.WEBAUTHN_RP_ID, fallback);
}

/** WEBAUTHN_ORIGIN (comma list), else APP_URL's origin, else http://localhost:3000. */
export function getAllowedOrigins(): string[] {
  const app = appUrlEnv();
  let fallback = ["http://localhost:3000"];
  if (app) {
    try {
      fallback = [new URL(app).origin];
    } catch {
      // an invalid APP_URL: keep the default
    }
  }
  return splitEnv(process.env.WEBAUTHN_ORIGIN, fallback);
}

/** The app's public URL, for links shown to users (setup links, invites). */
export function getAppUrl(): string {
  return (appUrlEnv() ?? getAllowedOrigins()[0]).replace(/\/+$/, "");
}

/** Cookies are `Secure` when the server is reached over HTTPS (APP_URL). */
export function cookieSecure(): boolean {
  return getAppUrl().startsWith("https://");
}

/** Host without port if allowed, else the first allowed id. */
export function resolveRpId(host: string, allowedRpIds: string[]): string {
  const bare = host.split(":")[0];
  return allowedRpIds.includes(bare) ? bare : allowedRpIds[0];
}
