import type { SearchListItem } from "./serialize";

type TFn = (key: string, vars?: Record<string, string | number>) => string;

/**
 * Human-readable criteria line for a search. Reflects EVERY active source: a
 * `both` search lists both the Doctolib and jameda specialities (each prefixed
 * with its source name to disambiguate); a single-source search shows just that
 * source's speciality — so a jameda-only search no longer renders the empty
 * Doctolib slug. Location and insurance sector follow.
 */
export function criteriaSummary(s: SearchListItem, t: TFn): string {
  const doctolib = s.sources === "doctolib" || s.sources === "both";
  const jameda = s.sources === "jameda" || s.sources === "both";
  const both = doctolib && jameda;

  const specialities: string[] = [];
  if (doctolib) {
    const label = s.specialityLabel || s.specialitySlug;
    if (label) specialities.push(both ? `${t("appointments.form.sourcesDoctolib")}: ${label}` : label);
  }
  if (jameda) {
    const label = s.jamedaSpecialityLabel || s.jamedaSpecialitySlug;
    if (label) specialities.push(both ? `${t("appointments.form.sourcesJameda")}: ${label}` : label);
  }

  const parts: string[] = [specialities.length ? specialities.join(" · ") : t("common.dash")];
  if (s.locationLabel) parts.push(s.locationLabel);
  if (s.insuranceSector)
    parts.push(
      s.insuranceSector === "public"
        ? t("appointments.form.insuranceSectorPublic")
        : t("appointments.form.insuranceSectorPrivate"),
    );
  return parts.join(" · ");
}

/** "every 30 min", "hourly", "cron: …" or "paused". */
export function scheduleSummary(s: Pick<SearchListItem, "enabled" | "scheduleType" | "scheduleMinutes" | "cron">, t: TFn): string {
  if (!s.enabled) return t("appointments.schedule.disabled");
  if (s.scheduleType === "MINUTES") return t("appointments.schedule.everyNMinutes", { minutes: s.scheduleMinutes ?? 0 });
  if (s.scheduleType === "CRON") return t("appointments.schedule.cron", { cron: s.cron ?? "" });
  if (s.scheduleType === "HOURLY") return t("appointments.schedule.hourly");
  return t("appointments.schedule.daily");
}
