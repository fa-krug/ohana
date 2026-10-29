// DoctolibSource — implements AppointmentSource for Doctolib.
// Provider-loop logic moved verbatim from lib/doctolib/pipeline.ts; the only
// changes are: every result gains `source: "doctolib"`, the ignore check uses
// ignoreKey(), and collectResults never throws on all-providers-failed.

import type { Db } from "@/lib/db";
import { mapPool } from "@/lib/appointments/concurrency";
import { type Booking, type Criteria, DoctolibClient, type Provider } from "@/lib/appointments/doctolib/client";
import { buildDoctolibUrl, searchCriteria } from "@/lib/appointments/doctolib/criteria";
import { PROFILE_CACHE_TTL_MS, loadProfilePayload } from "@/lib/appointments/doctolib/profile-cache";
import { ignoreKey } from "./keys";
import type { AppointmentSource, CollectOpts, CollectOutcome, NormalizedResult, SearchRow } from "./types";

const CONCURRENCY = Math.max(1, Number(process.env.DOCTOLIB_CONCURRENCY) || 5);

/** True when any concrete slot or the next_slot falls on/before the cutoff. */
export function hasSlotWithin(slots: string[], nextSlot: string | null, cutoff: Date): boolean {
  const within = (iso: string) => {
    const t = new Date(iso).getTime();
    return !Number.isNaN(t) && t <= cutoff.getTime();
  };
  return slots.some(within) || (nextSlot != null && within(nextSlot));
}

/**
 * False only when the search names a sector and every bookable agenda is explicitly
 * excluded from sector booking (`insurance_sector_enabled` is false). See the Django
 * `_accepts_sector` docstring: the profile-level `ssn_enabled` flag is NOT usable.
 */
export function acceptsSector(booking: Booking, sector: string | undefined): boolean {
  if (!sector) return true;
  const bookable = booking.agendas.filter((a) => !a.booking_disabled);
  if (bookable.length === 0) return true;
  return bookable.some((a) => a.insurance_sector_enabled !== false);
}

async function hasListAvailability(
  client: DoctolibClient,
  provider: Provider,
  sector: string | undefined,
  start: string,
  cutoff: Date,
): Promise<boolean> {
  const motiveId = provider.matchedVisitMotiveId;
  const agendaIds = provider.matchedAgendaIds ?? [];
  if (motiveId == null || agendaIds.length === 0) return true;
  const { slots, nextSlot } = client.parseSlots(
    await client.fetchAvailabilities(motiveId, agendaIds, [], start, sector),
  );
  return hasSlotWithin(slots, nextSlot, cutoff);
}

function agendaTuples(
  booking: Booking,
  motiveId: number,
): { agendaIds: number[]; practiceIds: number[] } {
  const agendaIds: number[] = [];
  const practiceIds = new Set<number>();
  for (const a of booking.agendas) {
    if (a.booking_disabled) continue;
    if (a.visit_motive_ids.includes(motiveId)) {
      agendaIds.push(a.id);
      if (a.practice_id !== null) practiceIds.add(a.practice_id);
    }
  }
  return { agendaIds, practiceIds: [...practiceIds].sort((x, y) => x - y) };
}

async function collectProviders(
  client: DoctolibClient,
  criteria: Criteria,
  maxPages: number,
): Promise<Provider[]> {
  const providers: Provider[] = [];
  const slugs = new Set<string>();
  let total: number | null = null;
  for (let page = 0; page < maxPages; page++) {
    const { total: t, providers: batch } = client.parseSearch(
      await client.searchProviders(criteria, page),
    );
    if (total === null) total = t;
    const fresh = batch.filter((p) => !slugs.has(p.slug));
    if (fresh.length === 0) break;
    for (const p of fresh) {
      slugs.add(p.slug);
      providers.push(p);
    }
    if (total && providers.length >= total) break;
  }
  return providers;
}

export async function processProvider(
  db: Db,
  client: DoctolibClient,
  provider: Provider,
  ignored: Set<string>,
  sector: string | undefined,
  start: string,
  cutoff: Date,
  now: Date,
): Promise<{ matched: boolean; results: NormalizedResult[] }> {
  const results: NormalizedResult[] = [];
  const payload = await loadProfilePayload(db, provider.slug, now, PROFILE_CACHE_TTL_MS, (s) =>
    client.fetchProfile(s),
  );
  const booking = client.parseBooking(payload);
  if (!acceptsSector(booking, sector)) return { matched: false, results };
  const matched = booking.motives.filter((m) => !ignored.has(ignoreKey("doctolib", provider.slug, m.id)));
  if (matched.length === 0) return { matched: false, results };

  // The doctor accepts the sector and has a non-ignored motive, so it counts as "matched"
  // ("passend") regardless of whether anything is bookable right now. The list-availability
  // gate then only short-circuits the expensive per-motive slot sweep: a doctor with nothing
  // upcoming within the day limit stays matched but yields no result rows.
  if (!(await hasListAvailability(client, provider, sector, start, cutoff))) {
    return { matched: true, results };
  }

  const bookingUrl = client.baseUrl + provider.path;
  const doctorName = booking.profile.name || provider.name;
  const practice = booking.places.length > 0 ? booking.places[0].name ?? "" : "";
  const place = booking.places.length > 0 ? booking.places[0] : undefined;
  const locationFields = {
    doctorSubtitle: booking.profile.subtitle ?? "",
    speciality: booking.profile.speciality ?? "",
    practiceAddress: place?.address ?? "",
    practiceCity: place?.city ?? "",
    practiceZipcode: place?.zipcode ?? "",
    practiceLatitude: place?.latitude != null ? String(place.latitude) : "",
    practiceLongitude: place?.longitude != null ? String(place.longitude) : "",
  };

  for (const motive of matched) {
    const { agendaIds, practiceIds } = agendaTuples(booking, motive.id);
    if (agendaIds.length === 0) continue;
    const payload = await client.fetchAvailabilities(motive.id, agendaIds, practiceIds, start, sector);
    const { slots, nextSlot } = client.parseSlots(payload);
    const seen = new Set<number>();
    for (const iso of slots) {
      const dt = new Date(iso);
      if (isNaN(dt.getTime()) || dt.getTime() > cutoff.getTime()) continue;
      seen.add(dt.getTime());
      results.push({
        source: "doctolib",
        ...locationFields,
        doctorName,
        motiveLabel: motive.name,
        practiceName: practice,
        bookingUrl,
        providerSlug: provider.slug,
        motiveId: motive.id,
        slotDatetime: dt,
        isNextSlot: false,
      });
    }
    if (nextSlot) {
      const ndt = new Date(nextSlot);
      if (!isNaN(ndt.getTime()) && ndt.getTime() <= cutoff.getTime() && !seen.has(ndt.getTime())) {
        results.push({
          source: "doctolib",
          ...locationFields,
          doctorName,
          motiveLabel: motive.name,
          practiceName: practice,
          bookingUrl,
          providerSlug: provider.slug,
          motiveId: motive.id,
          slotDatetime: ndt,
          isNextSlot: true,
        });
      }
    }
  }
  return { matched: true, results };
}

export class DoctolibSource implements AppointmentSource {
  readonly id = "doctolib" as const;
  constructor(private readonly client?: DoctolibClient) {}

  async collectResults(db: Db, search: SearchRow, opts: CollectOpts): Promise<CollectOutcome> {
    const criteria = searchCriteria(search);
    const sector = criteria.filters.insuranceSector;
    const start = opts.now.toISOString();
    const cutoff = new Date(opts.now.getTime() + opts.dayLimit * 24 * 60 * 60 * 1000);
    const cli = this.client ?? new DoctolibClient(buildDoctolibUrl(search));
    await cli.bootstrap(buildDoctolibUrl(search));

    const providers = await collectProviders(cli, criteria, opts.maxPages);
    const outcomes = await mapPool(providers, CONCURRENCY, async (provider) => {
      try {
        return await processProvider(db, cli, provider, opts.ignored, sector, start, cutoff, opts.now);
      } catch (exc) {
        return { error: `doctolib:${provider.slug}: ${(exc as Error).name}: ${(exc as Error).message}` };
      }
    });

    const results: NormalizedResult[] = [];
    const skipped: string[] = [];
    let doctorsMatched = 0;
    for (const o of outcomes) {
      if ("error" in o) { skipped.push(o.error); continue; }
      if (o.matched) doctorsMatched += 1;
      results.push(...o.results);
    }
    return { results, skipped, doctorsFound: providers.length, doctorsMatched };
  }
}
