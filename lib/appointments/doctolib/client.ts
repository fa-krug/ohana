// Doctolib JSON-API client — TypeScript port of the Django `DoctolibClient`.
//
// Split deliberately: the pure `parse*` functions are unit-tested with JSON fixtures;
// the network methods are thin `fetch` wrappers.
//
// NOTE on bot protection: the Django client used curl_cffi to impersonate Chrome's TLS
// fingerprint. Node's global fetch cannot do that, so we send Chrome-like headers and a
// per-instance cookie jar (bootstrap sets cookies the API calls need). This is the best
// a pure-Node port can do; if Doctolib tightens fingerprinting, network calls may need a
// TLS-impersonating fetch (e.g. a native curl-impersonate binding).

import { timeoutSignal } from "../http";

export class DoctolibHTTPError extends Error {
  constructor(
    public readonly statusCode: number,
    public readonly url: string,
  ) {
    super(`HTTP ${statusCode} for ${url}`);
    this.name = "DoctolibHTTPError";
  }
}

export interface Provider {
  slug: string;
  path: string;
  name: string;
  // The motive Doctolib matched to the search, used to render the list availability
  // badge — lets the pipeline cheaply gate a provider without a profile fetch.
  matchedVisitMotiveId?: number;
  matchedAgendaIds?: number[];
}

export interface Booking {
  profile: { id: number | null; name: string; subtitle: string; speciality: string };
  motives: { id: number; name: string }[];
  agendas: {
    id: number;
    visit_motive_ids: number[];
    practice_id: number | null;
    booking_disabled: boolean;
    insurance_sector_enabled: boolean | null;
  }[];
  places: { name?: string; address?: string; city?: string; zipcode?: string; latitude?: number; longitude?: number }[];
}

export interface Criteria {
  keyword: string;
  lat: string;
  lng: string;
  filters: { insuranceSector?: string };
}

const CHROME_HEADERS: Record<string, string> = {
  "User-Agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
  Accept: "application/json, text/plain, */*",
  "Accept-Language": "de-DE,de;q=0.9,en;q=0.8",
};

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export class DoctolibClient {
  readonly baseUrl: string;
  private readonly throttleMs: number;
  private readonly cookies = new Map<string, string>();

  constructor(baseUrl: string, throttleSeconds = 1.0) {
    const parsed = new URL(baseUrl);
    this.baseUrl = `${parsed.protocol}//${parsed.host}`;
    this.throttleMs = Math.round(throttleSeconds * 1000);
  }

  // --- parsing (pure, unit-tested) ---

  parseBooking(payload: Record<string, unknown>): Booking {
    const data = (payload.data ?? payload) as Record<string, unknown>;
    const profile = (data.profile ?? {}) as Record<string, unknown>;
    const speciality = ((profile.speciality ?? {}) as Record<string, unknown>).name ?? "";
    const motives = (data.visit_motives ?? []) as Record<string, unknown>[];
    const agendas = (data.agendas ?? []) as Record<string, unknown>[];
    return {
      profile: {
        id: (profile.id as number | null) ?? null,
        name: (profile.name_with_title as string) || (profile.name as string) || "",
        subtitle: String((profile.subtitle as string) ?? ""),
        speciality: String(speciality),
      },
      motives: motives.map((m) => ({ id: m.id as number, name: (m.name as string) ?? "" })),
      agendas: agendas.map((a) => ({
        id: a.id as number,
        visit_motive_ids: (a.visit_motive_ids as number[]) ?? [],
        practice_id: (a.practice_id as number | null) ?? null,
        booking_disabled: Boolean(a.booking_disabled ?? false),
        // Left null when absent so the pipeline only filters on an explicit false.
        insurance_sector_enabled:
          a.insurance_sector_enabled === undefined
            ? null
            : (a.insurance_sector_enabled as boolean | null),
      })),
      places: (data.places as Booking["places"]) ?? [],
    };
  }

  parseSearch(payload: Record<string, unknown>): { total: number; providers: Provider[] } {
    const providers: Provider[] = [];
    const hps = (payload.healthcareProviders ?? []) as Record<string, unknown>[];
    for (const hp of hps) {
      const link = String(hp.link ?? "").trim();
      // slug (last path segment) feeds the profile API; the full path is the
      // browser-facing profile URL.
      const slug = link.split("?")[0].replace(/\/+$/, "").split("/").pop() ?? "";
      if (slug) {
        const mv = (hp.matchedVisitMotive ?? {}) as Record<string, unknown>;
        providers.push({
          slug,
          path: link,
          name: String(hp.name ?? "").trim(),
          matchedVisitMotiveId: typeof mv.visitMotiveId === "number" ? mv.visitMotiveId : undefined,
          matchedAgendaIds: Array.isArray(mv.agendaIds) ? (mv.agendaIds as number[]) : undefined,
        });
      }
    }
    return { total: (payload.total as number) ?? 0, providers };
  }

  parseSlots(payload: Record<string, unknown>): { slots: string[]; nextSlot: string | null } {
    const slots: string[] = [];
    for (const day of (payload.availabilities ?? []) as Record<string, unknown>[]) {
      slots.push(...((day.slots as string[]) ?? []));
    }
    return { slots, nextSlot: (payload.next_slot as string | null) ?? null };
  }

  parseSpecialitySuggestions(payload: Record<string, unknown>): { slug: string; label: string }[] {
    const out: { slug: string; label: string }[] = [];
    for (const item of (payload.searchEntries ?? []) as Record<string, unknown>[]) {
      if (item.kind !== "SPECIALITY") continue;
      const slug = String(item.slug ?? "").trim();
      const label = String(item.name ?? "").trim();
      if (slug) out.push({ slug, label });
    }
    return out;
  }

  // --- network (thin wrappers) ---

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
    if (res.status >= 400) throw new DoctolibHTTPError(res.status, url);
    return res;
  }

  private async get(url: string): Promise<Response> {
    return this.request(url, { method: "GET" });
  }

  private async postJson(url: string, body: unknown): Promise<Response> {
    return this.request(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  }

  async suggestSpecialities(query: string): Promise<Record<string, unknown>> {
    // Bootstrap once for cookies (the autocomplete 410/429s on a cold session).
    await this.get(`${this.baseUrl}/search`);
    const res = await this.postJson(
      `${this.baseUrl}/patient-health-search/api/v1/autocomplete`,
      { query },
    );
    return res.json();
  }

  async bootstrap(listingUrl: string): Promise<void> {
    await this.get(listingUrl);
  }

  async searchProviders(criteria: Criteria, page = 0): Promise<Record<string, unknown>> {
    const body = {
      keyword: criteria.keyword,
      location: { gpsPoint: { lat: criteria.lat, lng: criteria.lng } },
      filters: criteria.filters ?? {},
    };
    const res = await this.postJson(
      `${this.baseUrl}/patient-health-search/api/v1/hcp/search?page=${page}`,
      body,
    );
    return res.json();
  }

  async fetchProfile(slug: string): Promise<Record<string, unknown>> {
    const params = new URLSearchParams({ profile_slug: slug, locale: "de" });
    const res = await this.get(
      `${this.baseUrl}/online_booking/api/slot_selection_funnel/v1/info.json?${params}`,
    );
    return res.json();
  }

  async fetchAvailabilities(
    visitMotiveId: number,
    agendaIds: number[],
    practiceIds: number[],
    startDateTime: string,
    insuranceSector?: string,
  ): Promise<Record<string, unknown>> {
    const params = new URLSearchParams({
      telehealth: "false",
      // The endpoint rejects limit > 7, so it is hard-capped at 7.
      limit: "7",
      start_date_time: startDateTime,
      visit_motive_id: String(visitMotiveId),
      agenda_ids: agendaIds.join("-"),
    });
    // Optional — the availability gate queries by agenda alone (it has no practice ids).
    if (practiceIds.length > 0) params.set("practice_ids", practiceIds.join("-"));
    // When a sector is searched, scope the availabilities query to it — the authoritative
    // gate (an agenda may be flagged bookable yet still return no public slot).
    if (insuranceSector) params.set("insurance_sector", insuranceSector);
    const res = await this.get(`${this.baseUrl}/search/availabilities.json?${params}`);
    return res.json();
  }
}
