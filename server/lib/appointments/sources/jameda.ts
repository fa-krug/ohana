import type { Db } from "@/lib/db";
import { mapPool } from "@/lib/appointments/concurrency";
import { JamedaClient, type JamedaDoctor, type JamedaFilters, type JamedaTarget, type JamedaTermType } from "@/lib/appointments/jameda/client";
import { citySlug } from "@/lib/appointments/jameda/city";
import { ignoreKey } from "./keys";
import type { AppointmentSource, CollectOpts, CollectOutcome, NormalizedResult, SearchRow } from "./types";

const CONCURRENCY = Math.max(1, Number(process.env.DOCTOLIB_CONCURRENCY) || 5);

export { citySlug };

/** Minimal surface of JamedaClient this source needs — lets tests inject a fake. */
export interface JamedaApi {
  bootstrap(): Promise<void>;
  searchListing(target: JamedaTarget, filters: JamedaFilters, page: number): Promise<string>;
  parseListing(html: string): JamedaDoctor[];
  fetchSlots(addressId: string, start: string, end: string): Promise<Record<string, unknown>>;
  fetchNextSlot(addressId: string): Promise<Record<string, unknown>>;
  parseSlots(payload: Record<string, unknown>): { slots: string[]; nextSlot: string | null };
}

export class JamedaSource implements AppointmentSource {
  readonly id = "jameda" as const;
  constructor(private readonly client?: JamedaApi) {}

  async collectResults(_db: Db, search: SearchRow, opts: CollectOpts): Promise<CollectOutcome> {
    if (!search.jamedaSpecialitySlug) return empty();
    const loc = (search.locationLabel.split(",")[0] ?? "").trim();
    if (!loc) return empty();
    const filters: JamedaFilters = {
      insuranceType: (search.jamedaInsuranceType || undefined) as JamedaFilters["insuranceType"],
      kidsFriendly: search.jamedaKidsFriendly,
      video: (search.jamedaVideo || "any") as JamedaFilters["video"],
    };
    const target: JamedaTarget = {
      type: (search.jamedaSpecialityType || "leistung") as JamedaTermType,
      slug: search.jamedaSpecialitySlug,
      label: search.jamedaSpecialityLabel || search.jamedaSpecialitySlug,
      loc,
      citySlug: citySlug(search.locationLabel),
    };

    const cli: JamedaApi = this.client ?? new JamedaClient();
    const cutoff = new Date(opts.now.getTime() + opts.dayLimit * 24 * 60 * 60 * 1000);
    const start = opts.now.toISOString().slice(0, 10);
    const end = cutoff.toISOString().slice(0, 10);
    await cli.bootstrap();

    // Collect doctors across pages, de-duped by addressId.
    const doctors: JamedaDoctor[] = [];
    const seenAddr = new Set<string>();
    const skipped: string[] = [];
    for (let page = 0; page < opts.maxPages; page++) {
      let batch: JamedaDoctor[];
      try {
        batch = cli.parseListing(await cli.searchListing(target, filters, page));
      } catch (exc) {
        skipped.push(`jameda:page${page}: ${(exc as Error).name}: ${(exc as Error).message}`);
        break;
      }
      if (filters.video === "exclude") batch = batch.filter((d) => !d.isOnlineOnly);
      const fresh = batch.filter((d) => !seenAddr.has(d.addressId));
      if (fresh.length === 0) break;
      for (const d of fresh) { seenAddr.add(d.addressId); doctors.push(d); }
    }

    const candidates = doctors.filter(
      (d) => d.hasSlots && !opts.ignored.has(ignoreKey("jameda", d.addressId, 0)),
    );

    const outcomes = await mapPool(candidates, CONCURRENCY, async (d) => {
      try {
        return { results: await slotsFor(cli, d, start, end, cutoff), matched: true };
      } catch (exc) {
        return { error: `jameda:${d.addressId}: ${(exc as Error).name}: ${(exc as Error).message}` };
      }
    });

    const results: NormalizedResult[] = [];
    let matched = 0;
    for (const o of outcomes) {
      if ("error" in o) { skipped.push(o.error as string); continue; }
      if (o.results.length > 0) matched += 1;
      results.push(...o.results);
    }
    return { results, skipped, doctorsFound: doctors.length, doctorsMatched: matched };
  }
}

function empty(): CollectOutcome {
  return { results: [], skipped: [], doctorsFound: 0, doctorsMatched: 0 };
}

function base(d: JamedaDoctor): Omit<NormalizedResult, "slotDatetime" | "isNextSlot"> {
  return {
    source: "jameda", doctorName: d.name.trim(), motiveLabel: "", practiceName: "",
    bookingUrl: d.bookingUrl, providerSlug: d.addressId, motiveId: 0,
    doctorSubtitle: "", speciality: d.speciality, practiceAddress: "",
    practiceCity: d.city, practiceZipcode: "", practiceLatitude: d.latitude, practiceLongitude: d.longitude,
  };
}

async function slotsFor(
  cli: JamedaApi, d: JamedaDoctor, start: string, end: string, cutoff: Date,
): Promise<NormalizedResult[]> {
  const out: NormalizedResult[] = [];
  const { slots } = cli.parseSlots(await cli.fetchSlots(d.addressId, start, end));
  const seen = new Set<number>();
  for (const iso of slots) {
    const dt = new Date(iso);
    if (isNaN(dt.getTime()) || dt.getTime() > cutoff.getTime()) continue;
    seen.add(dt.getTime());
    out.push({ ...base(d), slotDatetime: dt, isNextSlot: false });
  }
  if (out.length === 0) {
    const { slots: near } = cli.parseSlots(await cli.fetchNextSlot(d.addressId));
    const earliest = near
      .map((iso) => new Date(iso))
      .filter((dt) => !isNaN(dt.getTime()) && dt.getTime() <= cutoff.getTime())
      .sort((a, b) => a.getTime() - b.getTime())[0];
    if (earliest && !seen.has(earliest.getTime())) {
      out.push({ ...base(d), slotDatetime: earliest, isNextSlot: true });
    }
  }
  return out;
}
