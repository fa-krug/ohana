// How the chat names a tool call: what it does ("Reading transactions") and, in a few words,
// what it is about ("March 2026 · “Amazon”"), from the arguments the model passed.

import type { TVars } from "@/lib/i18n/translate";
import type { Item } from "./chat-store";

type ToolItem = Item & { kind: "tool" };
/** The translations, and the language for dates. */
export interface Lang {
  t: (key: string, vars?: TVars) => string;
  locale: string;
}
type Args = Record<string, unknown>;

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");
const date = (v: unknown) => (typeof v === "string" && DATE_RE.test(v) ? v : "");
const utc = (d: string) => new Date(`${d}T00:00:00Z`);
const fmt = (l: Lang, opts: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat(l.locale, { ...opts, timeZone: "UTC" });
const DAY: Intl.DateTimeFormatOptions = { day: "numeric", month: "short", year: "numeric" };
const lastOfMonth = (d: string) =>
  new Date(Date.UTC(+d.slice(0, 4), +d.slice(5, 7), 0)).getUTCDate();

/** A day range in short: "2026", "March 2026", "3 – 7 Aug 2026", "from 1 Mar 2026". */
export function span(l: Lang, from: string, to: string): string {
  if (from && to) {
    if (from > to) [from, to] = [to, from];
    if (from.endsWith("-01-01") && to.endsWith("-12-31")) {
      const a = from.slice(0, 4), b = to.slice(0, 4);
      return a === b ? a : `${a} – ${b}`;
    }
    if (
      from.slice(0, 7) === to.slice(0, 7) && from.endsWith("-01") &&
      +to.slice(8) === lastOfMonth(to)
    ) {
      return fmt(l, { month: "long", year: "numeric" }).format(utc(from));
    }
    if (from === to) return fmt(l, DAY).format(utc(from));
    return fmt(l, DAY).formatRange(utc(from), utc(to));
  }
  if (from) return l.t("assistant.detail.since", { d: fmt(l, DAY).format(utc(from)) });
  if (to) return l.t("assistant.detail.until", { d: fmt(l, DAY).format(utc(to)) });
  return "";
}

/** The days a list of ops touches, as one range. */
function opsSpan(l: Lang, ops: Args[]): string {
  const days = ops.flatMap((o) => [
    ...(Array.isArray(o.dates) ? o.dates.map(date) : []),
    date(o.from),
    date(o.to),
  ]).filter(Boolean).sort();
  return days.length ? span(l, days[0], days.at(-1)!) : "";
}

const quoted = (l: Lang, v: string) => (l.locale === "de" ? `„${v}“` : `“${v}”`);
/** An id or name the model passed: names are shown, ids (uuids) aren't worth reading. */
const named = (v: unknown) => {
  const s = str(v);
  return s && !UUID_RE.test(s) ? s : "";
};

/** What the tool is doing, e.g. "Reading transactions". */
export function toolLabel(l: Lang, item: ToolItem): string {
  const a = item.args ?? {};
  if (item.name === "web_search") {
    return l.t("assistant.tool.web_search", { q: String(a.query ?? "") });
  }
  if (item.name === "fetch_page") {
    let host = String(a.url ?? "");
    try {
      host = new URL(host).hostname;
    } catch {
      // keep as is
    }
    return l.t("assistant.tool.fetch_page", { host });
  }
  const key = `assistant.tool.${item.name}`;
  const label = l.t(key);
  // A tool of a later module the app doesn't know yet: its name.
  return label === key ? item.name : label;
}

/** What the call is about, in a few words ("" when there is nothing to add). */
export function toolDetail(l: Lang, item: ToolItem): string {
  const a: Args = item.args ?? {};
  const ops = (Array.isArray(a.ops) ? a.ops : []).filter(
    (o): o is Args => !!o && typeof o === "object",
  );
  const parts: string[] = [];
  switch (item.name) {
    case "get_calendar":
    case "finance_summary":
    case "combine_transfers":
      parts.push(span(l, date(a.from), date(a.to)));
      break;
    case "analyze_calendar": {
      parts.push(span(l, date(a.from), date(a.to)));
      const types = (Array.isArray(a.types) ? a.types : [a.types]).map(named).filter(Boolean);
      parts.push(types.slice(0, 2).join(", ") + (types.length > 2 ? " …" : ""));
      break;
    }
    case "calculate": {
      const list = Array.isArray(a.expressions) ? a.expressions : [a.expressions ?? a.expression];
      const first = str(list[0]);
      parts.push(first.length > 40 ? first.slice(0, 40) + "…" : first);
      if (list.length > 1) parts.push(`+${list.length - 1}`);
      break;
    }
    case "analyze_transactions":
    case "list_transactions": {
      // Several analyses in one call: the days they cover together, and how many.
      const queries = (Array.isArray(a.queries) ? a.queries : []).filter(
        (q): q is Args => !!q && typeof q === "object",
      );
      if (queries.length) {
        parts.push(opsSpan(l, queries.map((q) => ({ from: q.from ?? a.from, to: q.to ?? a.to }))));
      } else parts.push(span(l, date(a.from), date(a.to)));
      if (str(a.q)) parts.push(quoted(l, str(a.q)));
      if (str(a.account) === "none") parts.push(l.t("finance.noAccount"));
      else parts.push(named(a.account));
      if (str(a.category) === "none") parts.push(l.t("finance.uncategorized"));
      else parts.push(named(a.category));
      if (a.kind === "income") parts.push(l.t("finance.income"));
      if (a.kind === "expense") parts.push(l.t("finance.expenses"));
      if (a.kind === "transfer") parts.push(l.t("finance.transfers"));
      const offset = Math.floor(Number(a.offset)) || 0;
      if (offset > 0) parts.push(l.t("assistant.detail.fromRow", { n: offset + 1 }));
      if (queries.length) parts.push(l.t("assistant.detail.queries", { count: queries.length }));
      break;
    }
    case "change_entries": {
      const types = [
        ...new Set(
          ops.flatMap((o) => [o.type, ...(Array.isArray(o.types) ? o.types : [])].map(named)),
        ),
      ].filter(Boolean);
      parts.push(opsSpan(l, ops));
      parts.push(types.slice(0, 2).join(", ") + (types.length > 2 ? " …" : ""));
      break;
    }
    case "set_notes":
      parts.push(opsSpan(l, ops));
      break;
    case "change_transactions": {
      // A delete op can name many transactions.
      const n = ops.reduce(
        (sum, o) => sum + (o.action === "delete" && Array.isArray(o.ids) ? o.ids.length : 1),
        0,
      );
      if (n) parts.push(l.t("assistant.detail.changes", { count: n }));
      break;
    }
    case "manage_entry_types":
      if (a.action === "copy_year") {
        parts.push(`${a.from} → ${a.to}`);
      } else {
        const name = named(a.name) || named(a.type);
        if (name) parts.push(quoted(l, name));
        if (a.year) parts.push(String(a.year));
      }
      break;
    case "manage_categories": {
      const name = named(a.name) || named(a.category);
      if (name) parts.push(quoted(l, name));
      if (named(a.parent)) parts.push(`→ ${quoted(l, named(a.parent))}`);
      break;
    }
  }
  return parts.filter(Boolean).join(" · ");
}
