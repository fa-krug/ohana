import { index, integer, primaryKey, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";
import { families } from "../schema";
import { notificationChannels } from "./notifications";

// ---- appointments (findmyappointment's searches, family-scoped) ----

export const apptSearches = sqliteTable(
  "appt_searches",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    // Structured Doctolib target.
    specialitySlug: text("speciality_slug").notNull().default(""),
    specialityLabel: text("speciality_label").notNull().default(""),
    locationLabel: text("location_label").notNull().default(""),
    latitude: text("latitude").notNull().default(""),
    longitude: text("longitude").notNull().default(""),
    insuranceSector: text("insurance_sector").notNull().default(""), // "" | public | private
    // Which sources the search fans out to: "none" | "doctolib" | "jameda" | "both".
    sources: text("sources").notNull().default("doctolib"),
    jamedaSpecialitySlug: text("jameda_speciality_slug").notNull().default(""),
    jamedaSpecialityLabel: text("jameda_speciality_label").notNull().default(""),
    jamedaSpecialityType: text("jameda_speciality_type").notNull().default("leistung"),
    jamedaInsuranceType: text("jameda_insurance_type").notNull().default(""),
    jamedaKidsFriendly: integer("jameda_kids_friendly", { mode: "boolean" }).notNull().default(false),
    jamedaVideo: text("jameda_video").notNull().default("any"), // "any" | "only" | "exclude"
    dayLimit: integer("day_limit").notNull().default(14),
    maxPages: integer("max_pages").notNull().default(3),
    enabled: integer("enabled", { mode: "boolean" }).notNull().default(true),
    // Schedule config: MINUTES | HOURLY | DAILY | CRON
    scheduleType: text("schedule_type").notNull().default("MINUTES"),
    scheduleMinutes: integer("schedule_minutes").default(30),
    cron: text("cron").notNull().default(""),
    notifyOnlyEarlier: integer("notify_only_earlier", { mode: "boolean" }).notNull().default(false),
    /** Also push to the members' app devices (phase 9). */
    notifyApp: integer("notify_app", { mode: "boolean" }).notNull().default(true),
    earliestSeen: integer("earliest_seen", { mode: "timestamp" }),
    lastRunAt: integer("last_run_at", { mode: "timestamp" }),
    /** Interval schedules: when the worker runs it next. CRON: not before (the next minute
     *  after the last firing), so a minute never fires twice. */
    nextRunAt: integer("next_run_at", { mode: "timestamp" }),
    /** "Run now": set by the UI, picked up (and cleared) by the worker. */
    runRequestedAt: integer("run_requested_at", { mode: "timestamp" }),
    /** Lease of the worker running the search; no other worker claims it until then. */
    lockedUntil: integer("locked_until", { mode: "timestamp" }),
    lastStatus: text("last_status").notNull().default(""),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({
    apptSearchesFamilyIdx: index("appt_searches_family_idx").on(t.familyId),
    apptSearchesNextRunIdx: index("appt_searches_next_run_idx").on(t.nextRunAt),
  }),
);

export const apptSearchChannels = sqliteTable(
  "appt_search_channels",
  {
    searchId: text("search_id")
      .notNull()
      .references(() => apptSearches.id, { onDelete: "cascade" }),
    channelId: text("channel_id")
      .notNull()
      .references(() => notificationChannels.id, { onDelete: "cascade" }),
  },
  (t) => ({ pk: primaryKey({ columns: [t.searchId, t.channelId] }) }),
);

export const apptIgnored = sqliteTable(
  "appt_ignored",
  {
    id: integer("id").primaryKey({ autoIncrement: true }),
    searchId: text("search_id")
      .notNull()
      .references(() => apptSearches.id, { onDelete: "cascade" }),
    providerSlug: text("provider_slug").notNull(),
    source: text("source").notNull().default("doctolib"),
    motiveId: integer("motive_id").notNull(),
    doctorName: text("doctor_name").notNull().default(""),
    motiveLabel: text("motive_label").notNull().default(""),
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({
    apptIgnoredUniq: uniqueIndex("appt_ignored_uniq").on(t.searchId, t.source, t.providerSlug, t.motiveId),
  }),
);

export const apptRuns = sqliteTable(
  "appt_runs",
  {
    id: text("id").primaryKey(),
    searchId: text("search_id")
      .notNull()
      .references(() => apptSearches.id, { onDelete: "cascade" }),
    startedAt: integer("started_at", { mode: "timestamp" }).notNull(),
    finishedAt: integer("finished_at", { mode: "timestamp" }),
    status: text("status").notNull().default("RUNNING"), // RUNNING | OK | NO_AVAILABILITY | ERROR
    triggeredBy: text("triggered_by").notNull().default("SCHEDULE"), // SCHEDULE | MANUAL
    errorMessage: text("error_message").notNull().default(""),
    doctorsFound: integer("doctors_found").notNull().default(0),
    doctorsMatched: integer("doctors_matched").notNull().default(0),
    slotsFound: integer("slots_found").notNull().default(0),
    notified: integer("notified", { mode: "boolean" }).notNull().default(false),
  },
  (t) => ({
    apptRunsSearchIdx: index("appt_runs_search_idx").on(t.searchId, t.startedAt),
  }),
);

export const apptResults = sqliteTable(
  "appt_results",
  {
    id: integer("id").primaryKey({ autoIncrement: true }),
    runId: text("run_id")
      .notNull()
      .references(() => apptRuns.id, { onDelete: "cascade" }),
    doctorName: text("doctor_name").notNull(),
    motiveLabel: text("motive_label").notNull().default(""),
    practiceName: text("practice_name").notNull().default(""),
    bookingUrl: text("booking_url").notNull(),
    providerSlug: text("provider_slug").notNull().default(""),
    source: text("source").notNull().default("doctolib"),
    motiveId: integer("motive_id"),
    slotDatetime: integer("slot_datetime", { mode: "timestamp" }).notNull(),
    isNextSlot: integer("is_next_slot", { mode: "boolean" }).notNull().default(false),
    doctorSubtitle: text("doctor_subtitle").notNull().default(""),
    speciality: text("speciality").notNull().default(""),
    practiceAddress: text("practice_address").notNull().default(""),
    practiceCity: text("practice_city").notNull().default(""),
    practiceZipcode: text("practice_zipcode").notNull().default(""),
    practiceLatitude: text("practice_latitude").notNull().default(""),
    practiceLongitude: text("practice_longitude").notNull().default(""),
  },
  (t) => ({ apptResultsRunIdx: index("appt_results_run_idx").on(t.runId) }),
);

/** Each provider's near-static profile payload (motives, agendas, places), so scheduled
 *  runs don't refetch it every time. Shared by all families (it's public data). */
export const apptProfileCache = sqliteTable(
  "appt_profile_cache",
  {
    source: text("source").notNull().default("doctolib"),
    providerSlug: text("provider_slug").notNull(),
    payload: text("payload").notNull(),
    fetchedAt: integer("fetched_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({ pk: primaryKey({ columns: [t.source, t.providerSlug] }) }),
);
