// Jameda HTML/JSON client — parsing + network wrappers.
//
// Split deliberately: the pure `parseListing` / `parseSlots` are unit-tested with
// real fixtures; the network methods are thin fetch wrappers and are NOT unit-tested.
//
// NOTE on bot protection: we send Chrome-like headers and a per-instance cookie jar.
// `bootstrap()` seeds the cookie jar by hitting the homepage before scraping.

import { timeoutSignal } from "../http";

export type JamedaTermType = "specialization" | "leistung" | "erkrankung";

export interface JamedaFilters {
  insuranceType?: "" | "government" | "private" | "public_selfpay";
  kidsFriendly?: boolean;
  video?: "any" | "only" | "exclude";
}

export interface JamedaTarget {
  /** Term kind — only "specialization" routes to a landing page. */
  type: JamedaTermType;
  /** Speciality slug, used for the /{slug}/{citySlug} landing path. */
  slug: string;
  /** Free-text query label for the /suchen endpoint. */
  label: string;
  /** Raw city name for the /suchen `loc` param. */
  loc: string;
  /** Slugified city for the landing-page path. */
  citySlug: string;
}

/**
 * Pure: build a Jameda search URL.
 * - specialization (with slug + citySlug) → /{slug}/{citySlug} landing page (profession-precise)
 * - leistung / erkrankung → /suchen?q=<label>&loc=<city> free-text search
 */
export function jamedaListingUrl(
  baseUrl: string,
  target: JamedaTarget,
  filters: JamedaFilters,
  page: number,
): string {
  const extra = new URLSearchParams();
  if (filters.insuranceType) extra.append("filters[insurance_types][]", filters.insuranceType);
  if (filters.kidsFriendly) extra.append("filters[kids_friendly][]", "true");
  if (filters.video === "only") extra.append("filters[online_only][]", "true");
  if (page > 0) extra.set("page", String(page + 1));

  if (target.type === "specialization" && target.slug && target.citySlug) {
    const qs = extra.toString();
    return `${baseUrl}/${target.slug}/${target.citySlug}${qs ? `?${qs}` : ""}`;
  }

  const params = new URLSearchParams();
  params.set("q", target.label);
  params.set("loc", target.loc);
  for (const [k, v] of extra) params.append(k, v);
  return `${baseUrl}/suchen?${params.toString()}`;
}

export class JamedaHTTPError extends Error {
  constructor(
    public readonly statusCode: number,
    public readonly url: string,
  ) {
    super(`HTTP ${statusCode} for ${url}`);
    this.name = "JamedaHTTPError";
  }
}

export interface JamedaDoctor {
  doctorId: string;
  addressId: string;
  slug: string;
  name: string;
  bookingUrl: string;
  speciality: string;
  city: string;
  latitude: string;
  longitude: string;
  hasSlots: boolean;
  isOnlineOnly: boolean;
}

const CHROME_HEADERS: Record<string, string> = {
  "User-Agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
  Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "Accept-Language": "de-DE,de;q=0.9,en;q=0.8",
};

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Extract a named attribute value from an HTML opening tag substring. Returns "" if absent. */
function extractAttr(tag: string, name: string): string {
  // Match name="value" or name='value'
  const re = new RegExp(`${name}=["']([^"']*)["']`, "i");
  const m = tag.match(re);
  return m ? m[1] : "";
}

/** Returns true if a boolean attribute (no ="value") is present in the tag substring. */
function hasAttr(tag: string, name: string): boolean {
  // Must be preceded by whitespace/tab and followed by whitespace, tab, >, or another attribute
  const re = new RegExp(`(?:^|[\\s\\t])${name}(?:[\\s\\t>]|$)`, "i");
  return re.test(tag);
}

export class JamedaClient {
  readonly baseUrl: string;
  private readonly throttleMs: number;
  private readonly cookies = new Map<string, string>();

  constructor(throttleSeconds = 1.0) {
    this.baseUrl = "https://www.jameda.de";
    this.throttleMs = Math.round(throttleSeconds * 1000);
  }

  // --- parsing (pure, unit-tested) ---

  parseListing(html: string): JamedaDoctor[] {
    const doctors: JamedaDoctor[] = [];

    // Each result-item's opening tag starts with a block that includes data-id="result-item".
    // The tag spans multiple lines and ends with >.
    // Strategy: find the start of each tag (<div or any element) that contains data-id="result-item",
    // then capture everything up to the closing > of that opening tag.
    //
    // We find each occurrence of data-id="result-item" and then walk backwards to find
    // the '<' that started the tag, and forward to find the closing '>'.
    const marker = 'data-id="result-item"';
    let searchFrom = 0;

    while (true) {
      const markerPos = html.indexOf(marker, searchFrom);
      if (markerPos === -1) break;

      // Walk backwards to find the opening '<'
      let tagStart = markerPos;
      while (tagStart > 0 && html[tagStart] !== "<") tagStart--;

      // Walk forwards to find the closing '>' of the opening tag
      let tagEnd = markerPos + marker.length;
      while (tagEnd < html.length && html[tagEnd] !== ">") tagEnd++;
      tagEnd++; // include the '>'

      const tag = html.slice(tagStart, tagEnd);

      const doctorId = extractAttr(tag, "data-result-id");
      const addressId = extractAttr(tag, "data-address-id");

      // Skip entries without both IDs
      if (!doctorId || !addressId) {
        searchFrom = tagEnd;
        continue;
      }

      const name = extractAttr(tag, "data-doctor-name").trim();
      const bookingUrl = extractAttr(tag, "data-doctor-url");
      const speciality = extractAttr(tag, "data-eec-specialization-name");
      const city = extractAttr(tag, "data-eec-address-cities");
      // Coordinates live on a map element inside the card body, not the opening tag.
      // Scan the card slice (up to the next result-item) for the first data-lat/data-lng.
      const nextMarker = html.indexOf(marker, tagEnd);
      const cardBody = html.slice(tagEnd, nextMarker === -1 ? html.length : nextMarker);
      const latitude = extractAttr(cardBody, "data-lat");
      const longitude = extractAttr(cardBody, "data-lng");

      // slug = last non-empty path segment of bookingUrl
      const slug =
        bookingUrl
          .split("?")[0]
          .replace(/\/+$/, "")
          .split("/")
          .filter(Boolean)
          .pop() ?? "";

      // hasSlots: boolean attribute present in the tag
      const hasSlots = hasAttr(tag, "data-eec-has-calendar-with-slots");

      // isOnlineOnly: video-only provider (offers no in-person appointments)
      const isOnlineOnly = extractAttr(tag, "data-is-online-only") === "true";

      doctors.push({
        doctorId,
        addressId,
        slug,
        name,
        bookingUrl,
        speciality,
        city,
        latitude,
        longitude,
        hasSlots,
        isOnlineOnly,
      });

      searchFrom = tagEnd;
    }

    return doctors;
  }

  parseSlots(payload: Record<string, unknown>): { slots: string[]; nextSlot: string | null } {
    // Support both shapes:
    //   ranged:  { _items: [{start, booked, link}, ...] }
    //   nearest: { slots:  [{start, booked, link}, ...] }
    const raw =
      (payload._items as Record<string, unknown>[] | undefined) ??
      (payload.slots as Record<string, unknown>[] | undefined) ??
      [];

    const slots = raw
      .filter((entry) => entry.booked === false)
      .map((entry) => entry.start as string);

    return { slots, nextSlot: null };
  }

  // --- network (thin wrappers, not unit-tested) ---

  private storeCookies(res: Response): void {
    const setCookies = res.headers.getSetCookie?.() ?? [];
    for (const raw of setCookies) {
      const pair = raw.split(";")[0];
      const eq = pair.indexOf("=");
      if (eq > 0) this.cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
  }

  private cookieHeader(): string {
    return [...this.cookies.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
  }

  private async request(url: string, init: RequestInit = {}): Promise<Response> {
    if (this.throttleMs > 0) await sleep(this.throttleMs);
    const headers: Record<string, string> = {
      ...CHROME_HEADERS,
      Referer: `${this.baseUrl}/`,
      ...(init.headers as Record<string, string> | undefined),
    };
    const cookie = this.cookieHeader();
    if (cookie) headers.Cookie = cookie;
    const res = await fetch(url, { ...init, headers, redirect: "follow", signal: timeoutSignal() });
    this.storeCookies(res);
    if (res.status >= 400) throw new JamedaHTTPError(res.status, url);
    return res;
  }

  private async get(url: string, extraHeaders?: Record<string, string>): Promise<Response> {
    return this.request(url, { method: "GET", headers: extraHeaders });
  }

  async bootstrap(): Promise<void> {
    await this.get(`${this.baseUrl}/`);
  }

  async searchListing(
    target: JamedaTarget,
    filters: JamedaFilters,
    page: number,
  ): Promise<string> {
    const res = await this.get(jamedaListingUrl(this.baseUrl, target, filters, page));
    return res.text();
  }

  async fetchSlots(addressId: string, start: string, end: string): Promise<Record<string, unknown>> {
    const url = `${this.baseUrl}/ajax/doctor/slots/${addressId}.json?start=${start}&end=${end}`;
    const res = await this.get(url, { "X-Requested-With": "XMLHttpRequest" });
    return res.json();
  }

  async fetchNextSlot(addressId: string): Promise<Record<string, unknown>> {
    const url = `${this.baseUrl}/ajax/doctor/slots-from-nearest-day/${addressId}.json`;
    const res = await this.get(url, { "X-Requested-With": "XMLHttpRequest" });
    return res.json();
  }
}
