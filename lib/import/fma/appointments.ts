// findmyappointment: notification channels (family-wide in Ohana, tokens sealed), searches,
// their channels and ignore lists → Appointments. Runs, results and the profile cache stay
// behind (disposable, as findmyappointment's own Django import did).
import { apptIgnored, apptSearchChannels, apptSearches, notificationChannels } from "@/lib/db/schema";
import { all, bool, hasTable, int, intOrNull, sec, str } from "../sqlite";
import type { ImportContext } from "../types";

const PROVIDERS = new Set(["PUSHBULLET", "PUSHOVER", "TELEGRAM", "EMAIL"]);

export function importFmaAppointments(ctx: ImportContext): void {
  const src = ctx.sources.fma;
  if (!src) return;
  const { db } = ctx;
  const family = (householdId: unknown) => ctx.familyIds.fma.get(str(householdId));

  const channelIds = new Set<string>();
  for (const c of all(src.db, "SELECT * FROM notification_channels ORDER BY created_at")) {
    const familyId = family(c.household_id);
    if (!familyId) {
      ctx.skip("fma", "notification_channels", str(c.name), "its household isn't imported");
      continue;
    }
    const provider = str(c.provider, "PUSHBULLET");
    if (!PROVIDERS.has(provider)) {
      ctx.skip("fma", "notification_channels", str(c.name), `unknown provider ${provider}`);
      continue;
    }
    db.insert(notificationChannels)
      .values({
        id: str(c.id),
        familyId,
        name: str(c.name),
        provider,
        token: ctx.secrets.seal(str(c.token)), // plaintext in findmyappointment
        target: str(c.target),
        smtpHost: str(c.smtp_host),
        smtpPort: int(c.smtp_port, 465),
        smtpUsername: str(c.smtp_username),
        smtpFrom: str(c.smtp_from),
        enabled: bool(c.enabled),
        createdAt: sec(c.created_at) ?? ctx.now,
      })
      .run();
    channelIds.add(str(c.id));
  }

  const searchIds = new Set<string>();
  for (const s of all(src.db, "SELECT * FROM searches ORDER BY created_at")) {
    const familyId = family(s.household_id);
    if (!familyId) {
      ctx.skip("fma", "searches", str(s.name), "its household isn't imported");
      continue;
    }
    const createdAt = sec(s.created_at) ?? ctx.now;
    db.insert(apptSearches)
      .values({
        id: str(s.id),
        familyId,
        name: str(s.name),
        specialitySlug: str(s.speciality_slug),
        specialityLabel: str(s.speciality_label),
        locationLabel: str(s.location_label),
        latitude: str(s.latitude),
        longitude: str(s.longitude),
        insuranceSector: str(s.insurance_sector),
        sources: str(s.sources, "doctolib"),
        jamedaSpecialitySlug: str(s.jameda_speciality_slug),
        jamedaSpecialityLabel: str(s.jameda_speciality_label),
        jamedaSpecialityType: str(s.jameda_speciality_type, "leistung"),
        jamedaInsuranceType: str(s.jameda_insurance_type),
        jamedaKidsFriendly: bool(s.jameda_kids_friendly),
        jamedaVideo: str(s.jameda_video, "any"),
        dayLimit: int(s.day_limit, 14),
        maxPages: int(s.max_pages, 3),
        enabled: bool(s.enabled),
        scheduleType: str(s.schedule_type, "MINUTES"),
        scheduleMinutes: intOrNull(s.schedule_minutes),
        cron: str(s.cron),
        notifyOnlyEarlier: bool(s.notify_only_earlier),
        earliestSeen: sec(s.earliest_seen),
        lastRunAt: sec(s.last_run_at),
        // The worker picks the schedule up from here (a time in the past: it runs soon).
        nextRunAt: bool(s.enabled) ? sec(s.next_run_at) : null,
        runRequestedAt: null,
        lockedUntil: null,
        lastStatus: str(s.last_status),
        createdAt,
        updatedAt: sec(s.updated_at) ?? createdAt,
      })
      .run();
    searchIds.add(str(s.id));
  }

  for (const sc of all(src.db, "SELECT * FROM search_channels")) {
    if (!searchIds.has(str(sc.search_id)) || !channelIds.has(str(sc.channel_id))) continue;
    db.insert(apptSearchChannels).values({ searchId: str(sc.search_id), channelId: str(sc.channel_id) }).run();
  }

  for (const ig of all(src.db, "SELECT * FROM ignored_entries ORDER BY id")) {
    if (!searchIds.has(str(ig.search_id))) continue;
    db.insert(apptIgnored)
      .values({
        searchId: str(ig.search_id),
        providerSlug: str(ig.provider_slug),
        source: str(ig.source, "doctolib"),
        motiveId: int(ig.motive_id),
        doctorName: str(ig.doctor_name),
        motiveLabel: str(ig.motive_label),
        createdAt: sec(ig.created_at) ?? ctx.now,
      })
      .run();
  }

  const runs = !hasTable(src.db, "search_runs") ? 0 : (all(src.db, "SELECT count(*) AS n FROM search_runs")[0]?.n as number | undefined) ?? 0;
  if (runs > 0) ctx.skip("fma", "search_runs", `${runs} run(s) with their results`, "run history isn't imported");
}
