// What every tool file shares: the shapes of a tool, its result and its context, the phrases
// of the change summaries, and the checks and limits the tools have in common (ported from
// family-planner's ai/tools.ts, which is split by module here: calendar.ts, finance.ts,
// general.ts, web.ts, reminders.ts; a module adds its own file and registers it in index.ts).

import { HttpError } from "@/lib/api/http";
import type { CalendarStore } from "@/lib/calendar/store";
import { isValidDate } from "@/lib/calendar/dates";
import type { Db } from "@/lib/db";
import type { FinanceStore } from "@/lib/finance/store";
import type { NetOptions } from "../net";
import type { ToolSpec } from "../provider";
import type { SearchProvider } from "../store";
import type { RemindersEdit, RemindersSnapshot } from "./reminders";

export interface UndoStep {
  method: "POST" | "PATCH" | "DELETE";
  path: string;
  body?: unknown;
}

export interface Change {
  kind: string; // entries | notes | types | categories | transactions | benchmark | …
  summary: string;
  undo: UndoStep[];
}

/** A question for the user (ask_user): the turn stops until they answer. */
export interface Question {
  question: string;
  options: string[];
  /** Several options can be picked (else one); the user can always write their own answer. */
  multiple: boolean;
}

export interface ToolResult {
  result: unknown;
  summary: string;
  change?: Change;
  question?: Question;
  /** A change of the user's Reminders (edit_reminders): the turn stops until they apply or
   *  decline it in the app. */
  reminders?: RemindersEdit;
}

export interface ToolContext {
  /** The app's language, for the change summaries the user sees. */
  lang: "en" | "de";
  /** The calendar part of family-planner's Store, and its finance part. */
  calendar: CalendarStore;
  finance: FinanceStore;
  /** For tools of modules without a store interface (meals, appointments). */
  db: Db;
  familyId: string;
  /** Who the turn is for (the chat's user): changes of meals and appointments are theirs. */
  userId?: string;
  /** The user's day (YYYY-MM-DD), for "this week" and "before June". */
  today?: string;
  /** The clock (tests set it). */
  now?: () => Date;
  /** Look-ups on the outside (Doctolib, jameda, the geocoder); tests pass fakes. */
  lookups?: Partial<Lookups>;
  net: NetOptions;
  search: { provider: Exclude<SearchProvider, "none">; key: string } | null;
  /** The user's Reminders as the app sent them with the latest message; undefined: the app
   *  can't reach them (no access on the device), and the Reminders tools are off. */
  reminders?: RemindersSnapshot;
  signal?: AbortSignal;
}

/** What the appointment tools look up outside Ohana (lib/appointments; each with a timeout). */
export interface Lookups {
  doctolibSpecialities(query: string): Promise<{ slug: string; label: string }[]>;
  places(query: string): Promise<{ label: string; latitude: string; longitude: string }[]>;
}

export interface Tool {
  spec: ToolSpec["function"];
  write?: boolean;
  needsSearch?: boolean;
  /** Offered only when the app sent the user's Reminders (ToolContext.reminders). */
  needsReminders?: boolean;
  run(args: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult>;
}

export const PHRASES = {
  en: {
    days: (n: number) => `${n} ${n === 1 ? "day" : "days"} changed`,
    notes: (n: number) => `${n} ${n === 1 ? "note" : "notes"} changed`,
    typeAdded: (name: string, year: number) => `Added the type “${name}” (${year})`,
    typeChanged: (name: string, year: number) => `Changed the type “${name}” (${year})`,
    typesCopied: (n: number, from: number, to: number) => `Copied ${n} types from ${from} to ${to}`,
    categoryAdded: (name: string) => `Added the category “${name}”`,
    categoryChanged: (name: string) => `Changed the category “${name}”`,
    transactions: (n: number) => `${n} ${n === 1 ? "transaction" : "transactions"} changed`,
    transfers: (n: number) => `${n} ${n === 1 ? "transfer" : "transfers"} combined`,
    splits: (n: number) => `${n} split ${n === 1 ? "booking" : "bookings"} combined`,
    benchmarkSet: "Set the statistic average",
    benchmarkCleared: "Removed the statistic average",
  },
  de: {
    days: (n: number) => `${n} ${n === 1 ? "Tag" : "Tage"} geändert`,
    notes: (n: number) => `${n} ${n === 1 ? "Notiz" : "Notizen"} geändert`,
    typeAdded: (name: string, year: number) => `Art „${name}“ hinzugefügt (${year})`,
    typeChanged: (name: string, year: number) => `Art „${name}“ geändert (${year})`,
    typesCopied: (n: number, from: number, to: number) =>
      `${n} Arten von ${from} nach ${to} kopiert`,
    categoryAdded: (name: string) => `Kategorie „${name}“ hinzugefügt`,
    categoryChanged: (name: string) => `Kategorie „${name}“ geändert`,
    transactions: (n: number) => `${n} ${n === 1 ? "Buchung" : "Buchungen"} geändert`,
    transfers: (n: number) => `${n} ${n === 1 ? "Umbuchung" : "Umbuchungen"} zusammengefasst`,
    splits: (n: number) => `${n} ${n === 1 ? "Aufteilung" : "Aufteilungen"} zusammengefasst`,
    benchmarkSet: "Statistischen Durchschnitt festgelegt",
    benchmarkCleared: "Statistischen Durchschnitt entfernt",
  },
};

/** Changes that need the user's OK first; the model has to call again with confirmed: true. */
export const CONFIRM_DAYS = 31;
export const CONFIRM_TRANSACTIONS = 20;
export const MAX_RANGE_DAYS = 400;
export const MAX_PAGE_TEXT = 12000;
/** Characters of a tool result the model gets; longer ones are cut off. */
export const MAX_TOOL_RESULT = 16_000;
/** list_transactions: rows per call at most (fewer when they don't fit into MAX_TOOL_RESULT),
 *  and the characters of a description it shows. */
export const MAX_TX_ROWS = 500;
export const MAX_TX_DESCRIPTION = 100;
/** analyze_transactions: groups per call at most (fewer when they don't fit). */
export const MAX_GROUPS = 1000;
export const DEFAULT_GROUPS = 100;
/** analyze_transactions: analyses per call (queries), and characters of a query's label. */
export const MAX_QUERIES = 10;
export const MAX_LABEL = 60;
/** analyze_calendar: days per call at most (about ten years). */
export const MAX_ANALYZE_DAYS = 3700;
/** ask_user: options per question, and characters of the question and of an option. */
export const MAX_OPTIONS = 8;
export const MAX_QUESTION = 500;
export const MAX_OPTION = 150;
export const TX_COLUMNS = [
  "id",
  "date",
  "amountCents",
  "payee",
  "description",
  "categoryId",
  "accountId",
  "transferId",
  "splitOf",
  "note",
];

export class NeedsConfirmation extends Error {}

export function needConfirm(args: Record<string, unknown>, what: string) {
  if (args.confirmed !== true) {
    throw new NeedsConfirmation(
      `${what} Ask the user to confirm first, then call this tool again with "confirmed": true.`,
    );
  }
}

export function range(args: Record<string, unknown>) {
  const { from, to } = args;
  if (!isValidDate(from) || !isValidDate(to)) {
    throw new HttpError(400, "from/to must be YYYY-MM-DD");
  }
  if (from > to) throw new HttpError(400, "from must not be after to");
  return { from: from as string, to: to as string };
}

export const yearOf = (day: string) => Number(day.slice(0, 4));

export function choices<T extends string>(
  v: unknown,
  allowed: readonly T[],
  field: string,
  max = allowed.length,
): T[] | undefined {
  if (v === undefined || v === null) return undefined;
  const list = Array.isArray(v) ? v : [v];
  const bad = list.find((x) => !allowed.includes(x as T));
  if (bad !== undefined) {
    throw new HttpError(400, `${field} can only hold ${allowed.join(", ")}`);
  }
  const out = [...new Set(list as T[])];
  if (out.length > max) throw new HttpError(400, `${field} takes at most ${max} values`);
  return out;
}

/** The first elements of `items` whose JSON, with `head`, stays below `max` characters (the tool
 *  result limit). */
export function fitting<T>(head: unknown, items: T[], max = MAX_TOOL_RESULT): T[] {
  let size = JSON.stringify(head).length + 60;
  const out: T[] = [];
  for (const item of items) {
    size += JSON.stringify(item).length + 1;
    if (size > max && out.length) break;
    out.push(item);
  }
  return out;
}


export const opsSchema = (item: Record<string, unknown>) => ({
  type: "object",
  properties: {
    ops: { type: "array", items: item, description: "Applied in order." },
    confirmed: {
      type: "boolean",
      description: "Set only after the user confirmed a big change you described to them.",
    },
  },
  required: ["ops"],
});

