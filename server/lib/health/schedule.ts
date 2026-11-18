// What's recommended when (browser-safe, pure): Germany's check-ups for children and young
// people (U1–U11, J1, J2: G-BA Kinder-Richtlinie and Jugendgesundheitsuntersuchung; U10, U11 and
// J2 are paid by many health insurers, not by all) and the STIKO vaccination calendar, for
// children by visit (the vaccines given together at that age) and for adults (tetanus /
// diphtheria every ten years, from 60 flu and COVID-19 each autumn, pneumococcal, shingles in two
// doses, from 75 RSV). Flu and COVID-19 can be had by anyone; from 18 they're shown as optional
// (recorded, never due) until they're recommended.
//
// Ages: the Richtlinie counts in months / weeks / days *of life* (the 21st month of life is age
// 20 months), so "21.–24. Lebensmonat" is `from` 20 months, `to` 24 months, and its tolerance
// ("20.–27.") gives `until` 27 months. The yearly ones by their usual ages (U10 7–8 years).
// Vaccinations: `from` the STIKO age, `to` a month later, `until` the age after which it's a
// catch-up (still recordable, no longer "due").
//
// The schedule changes (STIKO yearly): SCHEDULE_AS_OF says which edition this is. The vaccination
// booklet (Impfpass) and the U-Heft are what counts; this only reminds.

export const SCHEDULE_AS_OF = "STIKO 2025 · G-BA 2025";

export type Lang = "en" | "de";
export type HealthKind = "checkup" | "vaccination";

/** An age: years, months, weeks and days after birth (added in that order). */
export interface Age {
  y?: number;
  m?: number;
  w?: number;
  d?: number;
}

export interface ScheduleItem {
  code: string;
  kind: HealthKind;
  /** Children's items are shown until 18, adults' from `from` (a second dose with its first). */
  group: "child" | "adult";
  title: Record<Lang, string>;
  detail: Record<Lang, string>;
  /** The vaccines (vaccinations only), as the booklet names them. */
  vaccines?: Record<Lang, string[]>;
  /** The window: due from `from`, recommended until `to`, recordable as on time until `until`. */
  from: Age;
  to: Age;
  until: Age;
  /** Not paid by every health insurer (U10, U11, J2). */
  notAlwaysPaid?: boolean;
  /** Again this long after the last one (tetanus: 10 years). */
  every?: Age;
  /** Due each autumn (flu, COVID-19): from 1 October to 31 March, a shot from August on counts. */
  seasonal?: boolean;
  /** A second dose: its ages count from the day the first (`after`) was given. */
  after?: string;
  /** Shown from this age on as optional (recordable, never due) until `from` (flu, COVID-19 from 18). */
  optionalFrom?: Age;
}

const both = (en: string, de: string): Record<Lang, string> => ({ en, de });

const checkup = (
  code: string,
  name: string,
  from: Age,
  to: Age,
  until: Age,
  detail: Record<Lang, string>,
  extra: Partial<ScheduleItem> = {},
): ScheduleItem => ({ code, kind: "checkup", group: "child", title: both(name, name), detail, from, to, until, ...extra });

const visit = (
  code: string,
  title: Record<Lang, string>,
  vaccines: Record<Lang, string[]>,
  from: Age,
  to: Age,
  until: Age,
  detail?: Record<Lang, string>,
  extra: Partial<ScheduleItem> = {},
): ScheduleItem => ({
  code,
  kind: "vaccination",
  group: "child",
  title,
  detail: detail ?? { en: vaccines.en.join(", "), de: vaccines.de.join(", ") },
  vaccines,
  from,
  to,
  until,
  ...extra,
});

const adult = (
  code: string,
  title: Record<Lang, string>,
  detail: Record<Lang, string>,
  from: Age,
  extra: Partial<ScheduleItem> = {},
): ScheduleItem => ({
  code,
  kind: "vaccination",
  group: "adult",
  title,
  detail,
  vaccines: { en: [title.en], de: [title.de] },
  from,
  to: from,
  until: from,
  ...extra,
});

const SIX = both("6-in-1", "6-fach");
const PCV = both("Pneumococcal", "Pneumokokken");
const MENB = both("Meningococcal B", "Meningokokken B");
const ROTA = both("Rotavirus", "Rotaviren");
const MMR = both("MMR", "MMR");
const VAR = both("Chickenpox", "Varizellen");
const EVERY_AUTUMN = both("Every autumn from 60; optional before", "Jeden Herbst ab 60; vorher freiwillig");
const ADULT_AGE = 18;
const dose = (v: Record<Lang, string>, n: number) => ({ en: `${v.en} (${n})`, de: `${v.de} (${n})` });
const list = (...v: Record<Lang, string>[]) => ({ en: v.map((x) => x.en), de: v.map((x) => x.de) });

export const SCHEDULE: ScheduleItem[] = [
  // ---- check-ups (U-Untersuchungen, J1 / J2) ----
  checkup("u1", "U1", { d: 0 }, { d: 0 }, { d: 1 }, both("Right after birth", "Direkt nach der Geburt")),
  checkup("u2", "U2", { d: 2 }, { d: 9 }, { d: 13 }, both("Days 3–10, often with the newborn screening", "3.–10. Lebenstag, oft mit dem Neugeborenen-Screening")),
  checkup("u3", "U3", { w: 3 }, { w: 5 }, { w: 8 }, both("Weeks 4–5, hip ultrasound", "4.–5. Lebenswoche, Hüft-Ultraschall")),
  checkup("u4", "U4", { m: 2 }, { m: 4 }, { m: 4, d: 15 }, both("Months 3–4", "3.–4. Lebensmonat")),
  checkup("u5", "U5", { m: 5 }, { m: 7 }, { m: 8 }, both("Months 6–7", "6.–7. Lebensmonat")),
  checkup("u6", "U6", { m: 9 }, { m: 12 }, { m: 14 }, both("Months 10–12", "10.–12. Lebensmonat")),
  checkup("u7", "U7", { m: 20 }, { m: 24 }, { m: 27 }, both("Months 21–24", "21.–24. Lebensmonat")),
  checkup("u7a", "U7a", { m: 33 }, { m: 36 }, { m: 38 }, both("Months 34–36", "34.–36. Lebensmonat")),
  checkup("u8", "U8", { m: 45 }, { m: 48 }, { m: 50 }, both("Months 46–48", "46.–48. Lebensmonat")),
  checkup("u9", "U9", { m: 59 }, { m: 64 }, { m: 66 }, both("Months 60–64, before school", "60.–64. Lebensmonat, vor der Einschulung")),
  checkup("u10", "U10", { y: 7 }, { y: 9 }, { y: 9 }, both("Age 7–8", "Mit 7–8 Jahren"), { notAlwaysPaid: true }),
  checkup("u11", "U11", { y: 9 }, { y: 11 }, { y: 11 }, both("Age 9–10", "Mit 9–10 Jahren"), { notAlwaysPaid: true }),
  checkup("j1", "J1", { y: 12 }, { y: 15 }, { y: 15 }, both("Age 12–14", "Mit 12–14 Jahren")),
  checkup("j2", "J2", { y: 16 }, { y: 18 }, { y: 18 }, both("Age 16–17", "Mit 16–17 Jahren"), { notAlwaysPaid: true }),

  // ---- children's vaccinations, by visit ----
  visit(
    "rsv-infant",
    both("RSV protection", "RSV-Prophylaxe"),
    { en: ["RSV antibody (nirsevimab)"], de: ["RSV-Antikörper (Nirsevimab)"] },
    { d: 0 },
    { m: 6 },
    { m: 12 },
    both("Once, before or in the first RSV season (October to March)", "Einmal, vor oder in der ersten RSV-Saison (Oktober bis März)"),
  ),
  visit("vac-6w", both("Vaccination at 6 weeks", "Impfung mit 6 Wochen"), list(dose(ROTA, 1)), { w: 6 }, { w: 8 }, { w: 12 }),
  visit("vac-2m", both("Vaccinations at 2 months", "Impfungen mit 2 Monaten"), list(dose(SIX, 1), dose(PCV, 1), dose(ROTA, 2), dose(MENB, 1)), { m: 2 }, { m: 3 }, { m: 4 }),
  visit("vac-4m", both("Vaccinations at 4 months", "Impfungen mit 4 Monaten"), list(dose(SIX, 2), dose(PCV, 2), dose(MENB, 2)), { m: 4 }, { m: 5 }, { m: 11 }),
  visit("vac-11m", both("Vaccinations at 11 months", "Impfungen mit 11 Monaten"), list(dose(SIX, 3), dose(PCV, 3), dose(MMR, 1), dose(VAR, 1)), { m: 11 }, { m: 12 }, { m: 15 }),
  visit("vac-12m", both("Vaccinations at 12 months", "Impfungen mit 12 Monaten"), list(both("Meningococcal C", "Meningokokken C"), dose(MENB, 3)), { m: 12 }, { m: 13 }, { m: 24 }),
  visit("vac-15m", both("Vaccinations at 15 months", "Impfungen mit 15 Monaten"), list(dose(MMR, 2), dose(VAR, 2)), { m: 15 }, { m: 16 }, { m: 24 }),
  visit("vac-5y", both("Booster at 5–6 years", "Auffrischung mit 5–6 Jahren"), { en: ["Tetanus, diphtheria, whooping cough"], de: ["Tetanus, Diphtherie, Keuchhusten"] }, { y: 5 }, { y: 7 }, { y: 9 }),
  visit("vac-9y", both("Booster at 9–16 years", "Auffrischung mit 9–16 Jahren"), { en: ["Tetanus, diphtheria, whooping cough, polio"], de: ["Tetanus, Diphtherie, Keuchhusten, Polio"] }, { y: 9 }, { y: 17 }, { y: 18 }),
  visit("hpv-1", both("HPV (1st dose)", "HPV (1. Impfung)"), { en: ["HPV (1)"], de: ["HPV (1)"] }, { y: 9 }, { y: 15 }, { y: 18 }, both("Age 9–14, two doses at least 5 months apart", "Mit 9–14 Jahren, zwei Impfungen mit mindestens 5 Monaten Abstand")),
  visit("hpv-2", both("HPV (2nd dose)", "HPV (2. Impfung)"), { en: ["HPV (2)"], de: ["HPV (2)"] }, { m: 5 }, { m: 13 }, { m: 13 }, both("5–13 months after the first", "5–13 Monate nach der ersten"), { after: "hpv-1" }),

  // ---- adults ----
  adult(
    "td",
    both("Tetanus / diphtheria", "Tetanus / Diphtherie"),
    both("Every 10 years; once with whooping cough", "Alle 10 Jahre; einmal mit Keuchhusten"),
    { y: 18 },
    { every: { y: 10 } },
  ),
  adult("flu", both("Flu", "Grippe"), EVERY_AUTUMN, { y: 60 }, { seasonal: true, optionalFrom: { y: ADULT_AGE } }),
  adult("covid", both("COVID-19", "COVID-19"), EVERY_AUTUMN, { y: 60 }, { seasonal: true, optionalFrom: { y: ADULT_AGE } }),
  adult("pneumo", both("Pneumococcal", "Pneumokokken"), both("Once from 60", "Einmal ab 60"), { y: 60 }),
  adult("shingles-1", both("Shingles (1st dose)", "Gürtelrose (1. Impfung)"), both("From 60, two doses", "Ab 60, zwei Impfungen"), { y: 60 }),
  adult(
    "shingles-2",
    both("Shingles (2nd dose)", "Gürtelrose (2. Impfung)"),
    both("2–6 months after the first", "2–6 Monate nach der ersten"),
    { m: 2 },
    { after: "shingles-1", to: { m: 6 }, until: { m: 6 } },
  ),
  adult("rsv", both("RSV", "RSV"), both("Once from 75", "Einmal ab 75"), { y: 75 }),
];

export const SCHEDULE_BY_CODE = new Map(SCHEDULE.map((i) => [i.code, i]));

// ---- dates ----

const pad = (n: number) => String(n).padStart(2, "0");

/** "YYYY-MM-DD" plus an age; a month end that doesn't exist falls on the month's last day. */
export function addAge(day: string, age: Age): string {
  let y = Number(day.slice(0, 4)) + (age.y ?? 0);
  let m = Number(day.slice(5, 7)) - 1 + (age.m ?? 0);
  y += Math.floor(m / 12);
  m = ((m % 12) + 12) % 12;
  const last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
  const d = Math.min(Number(day.slice(8, 10)), last);
  const t = Date.UTC(y, m, d) + ((age.w ?? 0) * 7 + (age.d ?? 0)) * 86_400_000;
  const r = new Date(t);
  return `${r.getUTCFullYear()}-${pad(r.getUTCMonth() + 1)}-${pad(r.getUTCDate())}`;
}

/** Whether an item is shown for someone born on `birthday`, on `today`: children's while under
 *  18 (and once born), adults' from their age on (an optional one's from `optionalFrom`). */
export function applies(item: ScheduleItem, birthday: string, today: string): boolean {
  if (item.group === "child") return today >= birthday && today < addAge(birthday, { y: ADULT_AGE });
  if (item.after) return applies(SCHEDULE_BY_CODE.get(item.after)!, birthday, today);
  return today >= addAge(birthday, item.optionalFrom ?? item.from);
}

/** Whether an item is only optional for someone born on `birthday`, on `today` (younger than its
 *  `from`). */
export function isOptional(item: ScheduleItem, birthday: string, today: string): boolean {
  return !!item.optionalFrom && today < addAge(birthday, item.from);
}

/** The items for someone born on `birthday`, on `today`. */
export function itemsFor(birthday: string, today: string): ScheduleItem[] {
  return SCHEDULE.filter((i) => applies(i, birthday, today));
}

/** The autumn season `today` belongs to: its first day (1 October), and from when a shot counts
 *  (1 August of that year). Before 1 April: last year's season. */
export function seasonOf(today: string): { start: string; counts: string; end: string } {
  const y = Number(today.slice(0, 4));
  const year = today.slice(5) < "04-01" ? y - 1 : y;
  return { start: `${year}-10-01`, counts: `${year}-08-01`, end: `${year + 1}-03-31` };
}
