// Pure calendar logic (no DOM) – shared by the calendar UI, the overview and the tests
// (ported from family-planner's app/src/lib/core.ts). Dates are ISO strings "YYYY-MM-DD";
// entries are Map<date, typeIds>, notes are Map<date, { icon, comment }>.

const DAY_MS = 86_400_000;

export type Role = "none" | "needs_cover" | "covers" | "day_off";
export const ROLES: Role[] = ["none", "needs_cover", "covers", "day_off"];

export interface EntryType {
  id: string;
  name: string;
  color: string;
  role: Role;
  year?: number;
  position?: number;
}

export interface Note {
  icon: string;
  comment: string;
}

export type Entries = Map<string, string[]>;
export type Notes = Map<string, Note>;
export type Pattern = string[][];

export interface EntryOp {
  action: "add" | "remove";
  type: string;
  dates: string[];
}

export interface NoteOp {
  action: "set" | "clear";
  dates: string[];
  icon?: string;
  comment?: string;
}

export const PALETTE = [
  "#3b82f6",
  "#ec4899",
  "#8b5cf6",
  "#14b8a6",
  "#f97316",
  "#84cc16",
  "#06b6d4",
  "#a855f7",
  "#eab308",
  "#64748b",
];

export function pad(n: number): string {
  return String(n).padStart(2, "0");
}

export function iso(year: number, month: number, day: number): string {
  return `${year}-${pad(month + 1)}-${pad(day)}`;
}

export function toUtc(date: string): Date {
  return new Date(date + "T00:00:00Z");
}

export function addDays(date: string, n: number): string {
  return new Date(toUtc(date).getTime() + n * DAY_MS).toISOString().slice(0, 10);
}

export function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
}

export function weekday(date: string): number {
  return toUtc(date).getUTCDay();
}

export function isWeekend(date: string): boolean {
  const w = weekday(date);
  return w === 0 || w === 6;
}

/** All dates of a year in order. */
export function yearDays(year: number): string[] {
  const out: string[] = [];
  for (let d = `${year}-01-01`; d.startsWith(String(year)); d = addDays(d, 1)) {
    out.push(d);
  }
  return out;
}

/** Inclusive date range, order-independent. */
export function range(a: string, b: string): string[] {
  if (a > b) [a, b] = [b, a];
  const out: string[] = [];
  for (let d = a; d <= b; d = addDays(d, 1)) out.push(d);
  return out;
}

export function roleMap(types: EntryType[]): Map<string, Role> {
  return new Map(types.map((t) => [t.id, t.role]));
}

/** A weekday that has a "needs cover" entry but no covering entry. */
export function isGap(date: string, ids: string[] | undefined, roles: Map<string, Role>): boolean {
  if (!ids || ids.length === 0 || isWeekend(date)) return false;
  let needs = false;
  for (const id of ids) {
    const r = roles.get(id);
    if (r === "covers" || r === "day_off") return false;
    if (r === "needs_cover") needs = true;
  }
  return needs;
}

export function gapDays(entries: Entries, types: EntryType[], year?: number): string[] {
  const roles = roleMap(types);
  const prefix = year === undefined ? "" : String(year);
  return [...entries]
    .filter(([d, ids]) => d.startsWith(prefix) && isGap(d, ids, roles))
    .map(([d]) => d)
    .sort();
}

/** Per type: total days and workdays (Mon–Fri that are not a day off). */
export function stats(
  entries: Entries,
  types: EntryType[],
  year?: number,
): Map<string, { days: number; workdays: number }> {
  const roles = roleMap(types);
  const out = new Map(types.map((t) => [t.id, { days: 0, workdays: 0 }]));
  for (const [date, ids] of entries) {
    if (year !== undefined && !date.startsWith(String(year))) continue;
    const weekend = isWeekend(date);
    const holiday = ids.some((id) => roles.get(id) === "day_off");
    for (const id of ids) {
      const s = out.get(id);
      if (!s) continue;
      s.days++;
      // A vacation day on a public holiday doesn't use up a vacation day.
      if (!weekend && (!holiday || roles.get(id) === "day_off")) s.workdays++;
    }
  }
  return out;
}

/** Clicking a type on a selection: remove it if every day has it, else add it everywhere. */
export function toggleType(entries: Entries, days: string[], typeId: string): Entries {
  const allHave = days.length > 0 && days.every((d) => (entries.get(d) ?? []).includes(typeId));
  const next: Entries = new Map();
  for (const d of days) {
    const cur = entries.get(d) ?? [];
    next.set(d, allHave ? cur.filter((id) => id !== typeId) : [...new Set([...cur, typeId])]);
  }
  return next;
}

export function clearDays(days: string[]): Entries {
  return new Map(days.map((d) => [d, []]));
}

/** Entries of the given days as a copy pattern (array of type id arrays). */
export function patternOf(entries: Entries, days: string[]): Pattern {
  return days.map((d) => [...(entries.get(d) ?? [])]);
}

/** Repeats `pattern` over `days` (cyclically) and returns the new day values. */
export function fillWith(days: string[], pattern: Pattern): Entries {
  const next: Entries = new Map();
  if (pattern.length === 0) return next;
  days.forEach((d, i) => next.set(d, [...pattern[i % pattern.length]]));
  return next;
}

/**
 * Days that a paste starting at `selection` should write to. A single selected
 * day receives the whole pattern; a larger selection is filled (repeating the
 * pattern) and nothing outside of it changes.
 */
export function pasteTargets(
  selection: string[],
  patternLength: number,
  maxDate: string,
  skipWeekends: boolean,
): string[] {
  if (selection.length !== 1) return selection;
  const out: string[] = [];
  for (let d = selection[0]; out.length < patternLength && d <= maxDate; d = addDays(d, 1)) {
    if (skipWeekends && isWeekend(d)) continue;
    out.push(d);
  }
  return out;
}

/** Only keeps days whose value actually changes. */
export function changedOnly(entries: Entries, next: Entries): Entries {
  const out: Entries = new Map();
  for (const [d, ids] of next) {
    const cur = entries.get(d) ?? [];
    const same = cur.length === ids.length && cur.every((id) => ids.includes(id));
    if (!same) out.set(d, ids);
  }
  return out;
}

/**
 * Converts day changes into add/remove API ops grouped per type. Add/remove
 * (rather than "set") merges nicely with concurrent edits by other people.
 */
export function toOps(entries: Entries, next: Entries): EntryOp[] {
  const add = new Map<string, string[]>();
  const remove = new Map<string, string[]>();
  for (const [d, ids] of next) {
    const cur = entries.get(d) ?? [];
    for (const id of ids) {
      if (!cur.includes(id)) (add.get(id) ?? add.set(id, []).get(id)!).push(d);
    }
    for (const id of cur) {
      if (!ids.includes(id)) {
        (remove.get(id) ?? remove.set(id, []).get(id)!).push(d);
      }
    }
  }
  const ops: EntryOp[] = [];
  for (const [type, dates] of remove) {
    ops.push({ action: "remove", type, dates: dates.sort() });
  }
  for (const [type, dates] of add) {
    ops.push({ action: "add", type, dates: dates.sort() });
  }
  return ops;
}

/** Applies day values to an entries map (in place). */
export function applyDays(entries: Entries, next: Entries): void {
  for (const [d, ids] of next) {
    if (ids.length) entries.set(d, [...ids]);
    else entries.delete(d);
  }
}

// Day notes: Map<date, { icon, comment }>, at most one per day. A change map
// uses null (or a note with neither icon nor comment) to remove a day's note.

type MaybeNote = Partial<Note> | null | undefined;

/** The note itself, or null if it has neither icon nor comment. */
export function noteOrNull(note: MaybeNote): Note | null {
  if (!note || !(note.icon || note.comment)) return null;
  return { icon: note.icon ?? "", comment: note.comment ?? "" };
}

export function sameNote(a: MaybeNote, b: MaybeNote): boolean {
  const x = noteOrNull(a);
  const y = noteOrNull(b);
  return x === y || (!!x && !!y && x.icon === y.icon && x.comment === y.comment);
}

/** Only keeps days whose note actually changes. */
export function changedNotesOnly(notes: Notes, next: Map<string, MaybeNote>): Map<string, Note | null> {
  const out = new Map<string, Note | null>();
  for (const [d, note] of next) {
    if (!sameNote(notes.get(d), note)) out.set(d, noteOrNull(note));
  }
  return out;
}

/** Converts note changes into API ops: one "set" per distinct note, one "clear" for removals. */
export function toNoteOps(next: Map<string, MaybeNote>): NoteOp[] {
  const sets = new Map<string, Note & { dates: string[] }>();
  const clear: string[] = [];
  for (const [d, note] of next) {
    const n = noteOrNull(note);
    if (!n) {
      clear.push(d);
      continue;
    }
    const key = JSON.stringify([n.icon, n.comment]);
    (sets.get(key) ?? sets.set(key, { ...n, dates: [] }).get(key)!).dates.push(d);
  }
  const ops: NoteOp[] = [];
  if (clear.length) ops.push({ action: "clear", dates: clear.sort() });
  for (const { icon, comment, dates } of sets.values()) {
    ops.push({ action: "set", dates: dates.sort(), icon, comment });
  }
  return ops;
}

/** Applies note changes to a notes map (in place). */
export function applyNotes(notes: Notes, next: Map<string, MaybeNote>): void {
  for (const [d, note] of next) {
    const n = noteOrNull(note);
    if (n) notes.set(d, n);
    else notes.delete(d);
  }
}

/** Clipboard text: one line per day, "YYYY-MM-DD<TAB>Type A, Type B". */
export function toClipboardText(days: string[], pattern: Pattern, types: EntryType[]): string {
  const names = new Map(types.map((t) => [t.id, t.name]));
  return days.map((d, i) => `${d}\t${pattern[i].map((id) => names.get(id) ?? id).join(", ")}`).join("\n");
}

/**
 * Parses clipboard text into a pattern. Accepts our own format as well as a
 * plain column of type names (e.g. pasted from a spreadsheet).
 */
export function parseClipboardText(text: string, types: EntryType[]): { pattern: Pattern; unknown: string[] } {
  const byName = new Map(types.map((t) => [t.name.toLowerCase(), t.id]));
  const ids = new Set(types.map((t) => t.id));
  const unknown = new Set<string>();
  const lines = text.replace(/\r/g, "").split("\n");
  while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
  const pattern = lines.map((line) => {
    const cells = line.split("\t");
    if (cells.length > 1 && /^\d{4}-\d{2}-\d{2}$/.test(cells[0].trim())) {
      cells.shift();
    }
    return cells
      .join(",")
      .split(/[,;+]/)
      .map((s) => s.trim())
      .filter(Boolean)
      .map((name) => {
        const id = byName.get(name.toLowerCase()) ?? (ids.has(name) ? name : null);
        if (!id) unknown.add(name);
        return id;
      })
      .filter((id): id is string => !!id);
  });
  return { pattern, unknown: [...unknown] };
}

/** Text color (black/white) that reads well on the given background. */
export function contrastText(hex: string): string {
  const n = parseInt(hex.slice(1), 16);
  const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  return (r * 299 + g * 587 + b * 114) / 1000 > 150 ? "#111827" : "#ffffff";
}

export function nextColor(types: EntryType[]): string {
  const used = new Set(types.map((t) => t.color.toLowerCase()));
  return PALETTE.find((c) => !used.has(c)) ?? PALETTE[types.length % PALETTE.length];
}
