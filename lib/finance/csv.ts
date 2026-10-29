// Bank statement CSV files: decoding, splitting into cells, and guessing how the columns map
// to transactions (German and English bank formats). No DOM, so tests/finance-csv.test.ts runs it.

import { parseMoney } from "./money";

export type Encoding = "utf-8" | "windows-1252";
export type DateFormat =
  | "YYYY-MM-DD"
  | "DD.MM.YYYY"
  | "DD.MM.YY"
  | "DD/MM/YYYY"
  | "MM/DD/YYYY";
export const DATE_FORMATS: DateFormat[] = [
  "YYYY-MM-DD",
  "DD.MM.YYYY",
  "DD.MM.YY",
  "DD/MM/YYYY",
  "MM/DD/YYYY",
];

/** How the columns of one bank's export map to transactions; saved per family. */
export interface CsvMapping {
  /** The header cells, to recognize the same bank's files later. */
  signature: string;
  encoding: Encoding;
  delimiter: string;
  /** Lines before the header (or the first row): banks often put account info there. */
  skipRows: number;
  hasHeader: boolean;
  date: number;
  dateFormat: DateFormat;
  /** One signed amount column, or separate debit / credit columns. */
  amount: number | null;
  debit: number | null;
  credit: number | null;
  decimal: "," | ".";
  payee: number | null;
  description: number[];
  /** The account this bank's statements are imported into. */
  accountId?: string;
  /** Whether transfers between accounts are combined on import (on when unset). */
  autoTransfers?: boolean;
}

export interface ParsedRow {
  date: string;
  amountCents: number;
  payee: string;
  description: string;
}

/** Decodes a file: UTF-8 if it is valid UTF-8, else Windows-1252 (older German banks). */
export function decode(
  bytes: Uint8Array,
  encoding?: Encoding,
): { text: string; encoding: Encoding } {
  if (encoding !== "windows-1252") {
    try {
      const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      return { text: text.replace(/^﻿/, ""), encoding: "utf-8" };
    } catch {
      if (encoding === "utf-8") throw new Error("The file is not valid UTF-8");
    }
  }
  return {
    text: new TextDecoder("windows-1252").decode(bytes),
    encoding: "windows-1252",
  };
}

/** Splits CSV text into rows of cells (quotes with "" escapes, newlines inside quotes). */
export function parseCsv(text: string, delimiter: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        cell += '"';
        i++;
      } else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"' && cell.trim() === "") {
      quoted = true;
      cell = "";
    } else if (ch === delimiter) {
      row.push(cell.trim());
      cell = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(cell.trim());
      rows.push(row);
      row = [];
      cell = "";
    } else cell += ch;
  }
  if (cell || row.length) {
    row.push(cell.trim());
    rows.push(row);
  }
  return rows.filter((r) => r.some((c) => c !== ""));
}

/** The delimiter that splits the first lines most consistently into the most columns. */
export function detectDelimiter(text: string): string {
  const lines = text.split(/\r?\n/).filter((l) => l.trim()).slice(0, 30);
  let best = ";", bestScore = -1;
  for (const d of [";", ",", "\t", "|"]) {
    const counts = lines.map((l) => parseCsv(l, d)[0]?.length ?? 0);
    const mode = modal(counts);
    const score = mode > 1 ? counts.filter((c) => c === mode).length * mode : 0;
    if (score > bestScore) [best, bestScore] = [d, score];
  }
  return best;
}

function modal(values: number[]): number {
  const n = new Map<number, number>();
  for (const v of values) n.set(v, (n.get(v) ?? 0) + 1);
  let best = 0, count = 0;
  for (const [v, c] of n) {
    if (c > count || (c === count && v > best)) [best, count] = [v, c];
  }
  return best;
}

const DATE_RES: Record<DateFormat, RegExp> = {
  "YYYY-MM-DD": /^(\d{4})-(\d{1,2})-(\d{1,2})/,
  "DD.MM.YYYY": /^(\d{1,2})\.(\d{1,2})\.(\d{4})/,
  "DD.MM.YY": /^(\d{1,2})\.(\d{1,2})\.(\d{2})(?!\d)/,
  "DD/MM/YYYY": /^(\d{1,2})\/(\d{1,2})\/(\d{4})/,
  "MM/DD/YYYY": /^(\d{1,2})\/(\d{1,2})\/(\d{4})/,
};

/** A date cell as YYYY-MM-DD, or null if it doesn't match the format or isn't a real day. */
export function parseDate(cell: string, format: DateFormat): string | null {
  const m = DATE_RES[format].exec(cell.trim());
  if (!m) return null;
  let y: number, mo: number, d: number;
  if (format === "YYYY-MM-DD") [y, mo, d] = [+m[1], +m[2], +m[3]];
  else if (format === "MM/DD/YYYY") [mo, d, y] = [+m[1], +m[2], +m[3]];
  else [d, mo, y] = [+m[1], +m[2], +m[3]];
  if (format === "DD.MM.YY") y += y < 70 ? 2000 : 1900;
  const date = new Date(Date.UTC(y, mo - 1, d));
  if (
    date.getUTCFullYear() !== y || date.getUTCMonth() !== mo - 1 ||
    date.getUTCDate() !== d
  ) {
    return null;
  }
  return `${y}-${String(mo).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

/** Whether at least 80% of the non-empty cells pass (a few broken rows don't spoil a guess). */
function mostly(cells: string[], ok: (cell: string) => boolean): boolean {
  const filled = cells.filter((c) => c.trim());
  return filled.length > 0 && filled.filter(ok).length >= filled.length * 0.8;
}

/** The format that reads (almost) all samples; DD/MM before MM/DD unless a day is > 12. */
export function detectDateFormat(samples: string[]): DateFormat | null {
  const cells = samples.filter((s) => s.trim());
  const count = (f: DateFormat) => cells.filter((c) => parseDate(c, f)).length;
  let best: DateFormat | null = null;
  for (const f of DATE_FORMATS) {
    if (
      mostly(cells, (c) => !!parseDate(c, f)) &&
      (!best || count(f) > count(best))
    ) best = f;
  }
  return best;
}

/** "," if the amounts look German (1.234,56), else ".". */
export function detectDecimal(samples: string[]): "," | "." {
  let comma = 0, dot = 0;
  for (const s of samples) {
    if (/,\d{1,2}(\D*)$/.test(s.trim())) comma++;
    else if (/\.\d{1,2}(\D*)$/.test(s.trim())) dot++;
  }
  return comma >= dot ? "," : ".";
}

const GUESS: Record<
  "date" | "amount" | "debit" | "credit" | "payee" | "description",
  RegExp
> = {
  date: /buchungstag|buchungsdatum|^datum|date|booking/i,
  amount: /betrag|amount|umsatz|^summe|value/i,
  debit: /^soll|debit|ausgang|withdrawal/i,
  credit: /^haben|credit|eingang|deposit/i,
  payee:
    /empf[äa]nger|auftraggeber|beg[üu]nstigter|zahlungspflichtiger|payee|counterparty|^name|gegenkonto.*name|partner/i,
  description: /verwendungszweck|buchungstext|description|purpose|memo|reference|details|text/i,
};

/**
 * Looks at a file and guesses a mapping: the delimiter, where the table starts (after a
 * preamble with fewer columns), whether it has a header, and which column is what.
 */
export function guessMapping(text: string, encoding: Encoding): CsvMapping {
  const delimiter = detectDelimiter(text);
  const rows = parseCsv(text, delimiter);
  const width = modal(rows.map((r) => r.length));
  const first = Math.max(0, rows.findIndex((r) => r.length === width));
  const head = rows[first] ?? [];
  // A header has no amounts and no dates.
  const hasHeader = head.length > 0 &&
    head.every((c) => parseMoney(c) === null || /[a-zäöü]/i.test(c)) &&
    !head.some((c) => detectDateFormat([c]));
  const data = rows.slice(first + (hasHeader ? 1 : 0)).filter((r) => r.length === width)
    .slice(0, 50);
  const column = (i: number) => data.map((r) => r[i] ?? "");
  const byName = (re: RegExp) => hasHeader ? head.findIndex((h) => re.test(h)) : -1;

  // Date: the named column if it parses, else the first column that does.
  let date = byName(GUESS.date);
  if (date < 0 || !detectDateFormat(column(date))) {
    date = head.map((_, i) => i).find((i) => detectDateFormat(column(i))) ?? 0;
  }
  const isAmounts = (i: number) => i >= 0 && mostly(column(i), (c) => parseMoney(c) !== null);
  let amount: number | null = byName(GUESS.amount);
  const debit = byName(GUESS.debit), credit = byName(GUESS.credit);
  const split = debit >= 0 && credit >= 0 && isAmounts(debit) &&
    isAmounts(credit);
  if (!isAmounts(amount)) {
    amount = split
      ? null
      : (head.map((_, i) => i).filter((i) => i !== date).find((i) =>
        isAmounts(i) && column(i).some((c) => /[,.]\d{2}/.test(c))
      ) ?? null);
  }
  const used = new Set([
    date,
    amount ?? -1,
    split ? debit : -1,
    split ? credit : -1,
  ]);
  let payee: number | null = byName(GUESS.payee);
  if (payee < 0 || used.has(payee)) payee = null;
  if (payee !== null) used.add(payee);
  const named = byName(GUESS.description);
  let description = named >= 0 && !used.has(named) ? [named] : [];
  if (!description.length) {
    // The column with the longest texts.
    const text = head.map((_, i) => i).filter((i) => !used.has(i) && !isAmounts(i))
      .sort((a, b) => avgLength(column(b)) - avgLength(column(a)));
    description = text.slice(0, 1);
  }
  const amounts = amount !== null ? column(amount) : [...column(debit), ...column(credit)];
  return {
    signature: hasHeader ? head.join(delimiter) : "",
    encoding,
    delimiter,
    skipRows: first,
    hasHeader,
    date,
    dateFormat: detectDateFormat(column(date)) ?? "DD.MM.YYYY",
    amount,
    debit: amount === null && split ? debit : null,
    credit: amount === null && split ? credit : null,
    decimal: detectDecimal(amounts),
    payee,
    description,
  };
}

function avgLength(cells: string[]) {
  return cells.reduce((n, c) => n + c.length, 0) / (cells.length || 1);
}

/** The table part of the file under a mapping: header cells and data rows. */
export function tableOf(text: string, mapping: CsvMapping) {
  const rows = parseCsv(text, mapping.delimiter).slice(mapping.skipRows);
  const header = mapping.hasHeader ? rows[0] ?? [] : [];
  return { header, rows: mapping.hasHeader ? rows.slice(1) : rows };
}

/** Applies a mapping to data rows; rows that don't parse come back as errors. */
export function mapRows(rows: string[][], m: CsvMapping) {
  const ok: (ParsedRow & { line: number })[] = [];
  const errors: { line: number; reason: "date" | "amount" }[] = [];
  rows.forEach((r, line) => {
    const date = parseDate(r[m.date] ?? "", m.dateFormat);
    if (!date) return errors.push({ line, reason: "date" });
    let cents: number | null;
    if (m.amount !== null) cents = parseMoney(r[m.amount] ?? "", m.decimal);
    else {
      // Debit / credit: debits may be written with or without a minus.
      const debit = parseMoney(r[m.debit ?? -1] ?? "", m.decimal);
      const credit = parseMoney(r[m.credit ?? -1] ?? "", m.decimal);
      cents = debit === null && credit === null
        ? null
        : (credit ? Math.abs(credit) : 0) - (debit ? Math.abs(debit) : 0);
    }
    if (cents === null) return errors.push({ line, reason: "amount" });
    ok.push({
      line,
      date,
      amountCents: cents,
      payee: m.payee !== null ? (r[m.payee] ?? "").slice(0, 200) : "",
      description: m.description.map((i) => r[i] ?? "").filter(Boolean).join(
        " ",
      ).replace(
        /\s+/g,
        " ",
      ).slice(0, 500),
    });
  });
  return { ok, errors };
}
