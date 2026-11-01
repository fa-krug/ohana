// Push to the app (phase 9): the relay this server sends through. A self-hosted server can't
// sign APNs requests for the App Store app (that takes the developer's key), so fa-krug runs a
// relay that holds the key and forwards end-to-end encrypted payloads (relay/). PUSH_RELAY_URL
// chooses it: unset means fa-krug's, empty turns push to the app off.

export const DEFAULT_PUSH_RELAY_URL = "https://ohana-push.fa-krug.de";

/** The relay's base URL without a trailing slash, or null when push is off. */
export function pushRelayUrl(env: Record<string, string | undefined> = process.env): string | null {
  const raw = env.PUSH_RELAY_URL;
  if (raw === undefined) return DEFAULT_PUSH_RELAY_URL;
  const url = raw.trim().replace(/\/+$/, "");
  if (!url || url === "off") return null;
  try {
    const u = new URL(url);
    if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error();
  } catch {
    console.warn(`[push] PUSH_RELAY_URL "${url}" isn't an http(s) URL: push to the app is off`);
    return null;
  }
  return url;
}

/** Two relay URLs name the same relay (case of the host, a trailing slash). */
export function sameRelay(a: string, b: string): boolean {
  try {
    const x = new URL(a);
    const y = new URL(b);
    const path = (u: URL) => u.pathname.replace(/\/+$/, "");
    return x.origin === y.origin && path(x) === path(y);
  } catch {
    return false;
  }
}
