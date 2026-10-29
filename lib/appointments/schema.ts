import { z } from "zod";

export const SCHEDULE_TYPES = ["MINUTES", "HOURLY", "DAILY", "CRON"] as const;
export const INSURANCE_SECTORS = ["", "public", "private"] as const;
export const JAMEDA_INSURANCE_TYPES = ["", "government", "private", "public_selfpay"] as const;
export const JAMEDA_TERM_TYPES = ["specialization", "leistung", "erkrankung"] as const;
export const JAMEDA_VIDEO_MODES = ["any", "only", "exclude"] as const;
// "none" = no source selected (both switches off) — a valid, no-op search.
export const SOURCES = ["none", "doctolib", "jameda", "both"] as const;

export const searchInputSchema = z
  .object({
    name: z.string().trim().min(1).max(200),
    sources: z.enum(SOURCES).default("doctolib"),
    specialitySlug: z.string().trim().default(""),
    specialityLabel: z.string().trim().default(""),
    jamedaSpecialitySlug: z.string().trim().default(""),
    jamedaSpecialityLabel: z.string().trim().default(""),
    jamedaSpecialityType: z.enum(JAMEDA_TERM_TYPES).default("leistung"),
    jamedaInsuranceType: z.enum(JAMEDA_INSURANCE_TYPES).default(""),
    jamedaKidsFriendly: z.boolean().default(false),
    jamedaVideo: z.enum(JAMEDA_VIDEO_MODES).default("any"),
    latitude: z.string().trim().min(1, "Pick a location from the suggestions."),
    longitude: z.string().trim().min(1, "Pick a location from the suggestions."),
    locationLabel: z.string().trim().default(""),
    insuranceSector: z.enum(INSURANCE_SECTORS).default(""),
    dayLimit: z.coerce.number().int().min(1).max(365).default(14),
    maxPages: z.coerce.number().int().min(1).max(20).default(3),
    enabled: z.boolean().default(true),
    scheduleType: z.enum(SCHEDULE_TYPES).default("MINUTES"),
    scheduleMinutes: z.coerce.number().int().min(1).max(1440).nullable().default(30),
    cron: z.string().trim().max(100).default(""),
    notifyOnlyEarlier: z.boolean().default(false),
    channelIds: z.array(z.string()).default([]),
  })
  .superRefine((v, ctx) => {
    const doctolib = v.sources === "doctolib" || v.sources === "both";
    const jameda = v.sources === "jameda" || v.sources === "both";
    if (doctolib && !v.specialitySlug)
      ctx.addIssue({ code: "custom", path: ["specialitySlug"], message: "Pick a Doctolib speciality." });
    if (jameda && !v.jamedaSpecialitySlug)
      ctx.addIssue({ code: "custom", path: ["jamedaSpecialitySlug"], message: "Pick a jameda speciality." });
    if (v.scheduleType === "CRON" && v.cron.trim().split(/\s+/).length !== 5)
      ctx.addIssue({ code: "custom", path: ["cron"], message: "A cron expression has five fields (m h dom mon dow)." });
  });

export type SearchInput = z.infer<typeof searchInputSchema>;
