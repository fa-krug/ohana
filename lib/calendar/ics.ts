// Builds an iCalendar (RFC 5545) feed that Apple Calendar / iCloud can
// subscribe to. Consecutive days of the same entry type (or the same day
// note) become one all-day event. Ported from family-planner's _shared/ics.ts.

import { addDays, consecutiveRuns, isWeekend } from "./dates";
import type { TypeRow } from "./store";

export interface IcsInput {
  calendarName: string;
  uidPrefix: string;
  /** Types of all years; a day's type ids refer to the types of that day's year. */
  types: TypeRow[];
  /** day -> type ids */
  entries: Map<string, string[]>;
  /** Only these types become events (all types if omitted). */
  include?: Set<TypeRow>;
  /** Adds a warning event for weekdays that need cover but have none. */
  gaps?: boolean;
  /** day -> note; each note (run of identical notes) becomes an event if set. */
  notes?: Map<string, { icon: string; comment: string }>;
  /** Timed events (booked appointments, phase 7); each becomes an event at its wall-clock time
   *  ("floating": the subscriber's own time zone). */
  events?: IcsEvent[];
  /** Language of generated texts (gap summaries, descriptions). Default "en". */
  lang?: Lang;
  now?: Date;
}

export type Lang = "en" | "de";

export interface IcsEvent {
  id: string;
  day: string;
  start: string | null; // HH:MM; null: all day
  end: string | null;
  title: string;
  location: string;
  person: string;
  note: string;
  url: string;
}

const TEXT: Record<Lang, { notCovered: string; span: (days: number, work: number) => string }> = {
  en: {
    notCovered: "⚠ Not covered",
    span: (days, work) => `${days} days (${work} workdays)`,
  },
  de: {
    notCovered: "⚠ Nicht abgedeckt",
    span: (days, work) => `${days} Tage (${work} ${work === 1 ? "Arbeitstag" : "Arbeitstage"})`,
  },
};

export function escapeText(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}

/** Folds a content line to max. 75 octets per line (RFC 5545 §3.1). */
export function foldLine(line: string): string {
  const enc = new TextEncoder();
  if (enc.encode(line).length <= 75) return line;
  const parts: string[] = [];
  let current = "";
  let size = 0;
  for (const ch of line) {
    const n = enc.encode(ch).length;
    const limit = parts.length === 0 ? 75 : 74; // continuation lines start with a space
    if (size + n > limit) {
      parts.push(current);
      current = "";
      size = 0;
    }
    current += ch;
    size += n;
  }
  parts.push(current);
  return parts.join("\r\n ");
}

const compact = (d: string) => d.replace(/-/g, "");

function stamp(now: Date): string {
  return now
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}/, "");
}

export function gapDays(types: TypeRow[], entries: Map<string, string[]>): string[] {
  const role = new Map(types.map((t) => [`${t.year}|${t.id}`, t.role]));
  const out: string[] = [];
  for (const [day, ids] of entries) {
    if (isWeekend(day)) continue;
    const roles = ids.map((id) => role.get(`${day.slice(0, 4)}|${id}`));
    if (!roles.includes("needs_cover")) continue;
    if (roles.includes("covers") || roles.includes("day_off")) continue;
    out.push(day);
  }
  return out.sort();
}

function workdays(days: string[]): number {
  return days.filter((d) => !isWeekend(d)).length;
}

// Event UIDs end in "@vacation-planner", the name from before the rename: changing them would
// make subscribed calendars treat every event as a new one.
export function buildIcs(input: IcsInput): string {
  const now = input.now ?? new Date();
  const text = TEXT[input.lang ?? "en"];
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//family-planner//Year Calendar//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "X-WR-CALNAME:" + escapeText(input.calendarName),
    "REFRESH-INTERVAL;VALUE=DURATION:PT1H",
    "X-PUBLISHED-TTL:PT1H",
  ];

  const event = (uid: string, run: string[], summary: string, detail = summary) => {
    const n = run.length;
    const description = n === 1 ? detail : `${detail}: ${text.span(n, workdays(run))}`;
    lines.push(
      "BEGIN:VEVENT",
      `UID:${uid}`,
      `DTSTAMP:${stamp(now)}`,
      `DTSTART;VALUE=DATE:${compact(run[0])}`,
      `DTEND;VALUE=DATE:${compact(addDays(run[n - 1], 1))}`,
      "SUMMARY:" + escapeText(summary),
      "DESCRIPTION:" + escapeText(description),
      "TRANSP:TRANSPARENT",
      "END:VEVENT",
    );
  };

  for (const type of input.types) {
    if (input.include && !input.include.has(type)) continue;
    const year = `${type.year}-`;
    const days = [...input.entries]
      .filter(([day, ids]) => day.startsWith(year) && ids.includes(type.id))
      .map(([day]) => day)
      .sort();
    for (const run of consecutiveRuns(days)) {
      event(`${input.uidPrefix}-${type.id}-${run[0]}@vacation-planner`, run, type.name);
    }
  }

  if (input.gaps) {
    const needs = [...new Set(input.types.filter((t) => t.role === "needs_cover").map((t) => t.name))];
    const label = text.notCovered + (needs.length ? ": " + needs.join(", ") : "");
    for (const run of consecutiveRuns(gapDays(input.types, input.entries))) {
      event(`${input.uidPrefix}-gap-${run[0]}@vacation-planner`, run, label);
    }
  }

  if (input.notes) {
    // Group days by identical icon + comment, then merge consecutive days.
    const groups = new Map<string, { icon: string; comment: string; days: string[] }>();
    for (const [day, { icon, comment }] of input.notes) {
      const key = icon + "\u0000" + comment;
      const group = groups.get(key) ?? { icon, comment, days: [] };
      group.days.push(day);
      groups.set(key, group);
    }
    const runs = [...groups.values()]
      .flatMap((g) => consecutiveRuns(g.days.sort()).map((run) => ({ ...g, run })))
      .sort((a, b) => a.run[0].localeCompare(b.run[0]));
    for (const { icon, comment, run } of runs) {
      const summary = `${icon} ${comment.split(/\r?\n/)[0]}`.trim();
      event(`${input.uidPrefix}-note-${run[0]}@vacation-planner`, run, summary, comment || summary);
    }
  }

  for (const e of input.events ?? []) {
    const summary = e.person ? `${e.title} (${e.person})` : e.title;
    const description = [e.note, e.url].filter(Boolean).join("\n");
    const when = e.start
      ? [
          `DTSTART:${compact(e.day)}T${e.start.replace(":", "")}00`,
          e.end ? `DTEND:${compact(e.day)}T${e.end.replace(":", "")}00` : "DURATION:PT1H",
        ]
      : [`DTSTART;VALUE=DATE:${compact(e.day)}`, `DTEND;VALUE=DATE:${compact(addDays(e.day, 1))}`];
    lines.push(
      "BEGIN:VEVENT",
      `UID:${input.uidPrefix}-event-${e.id}@ohana`,
      `DTSTAMP:${stamp(now)}`,
      ...when,
      "SUMMARY:" + escapeText(summary),
      ...(e.location ? ["LOCATION:" + escapeText(e.location)] : []),
      ...(description ? ["DESCRIPTION:" + escapeText(description)] : []),
      ...(/^https?:\/\//i.test(e.url) ? ["URL:" + e.url] : []),
      "END:VEVENT",
    );
  }

  lines.push("END:VCALENDAR");
  return lines.map(foldLine).join("\r\n") + "\r\n";
}
