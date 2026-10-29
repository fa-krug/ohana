// Money as integer cents: formatting and parsing what people type ("12,50", "-1.234,56").

const formatters = new Map<string, Intl.NumberFormat>();

export function formatMoney(
  cents: number,
  currency: string,
  lang: string,
  { sign = false, compact = false, whole = false } = {},
): string {
  const key = `${lang}|${currency}|${sign}|${compact}|${whole}`;
  let f = formatters.get(key);
  if (!f) {
    f = new Intl.NumberFormat(lang, {
      style: "currency",
      currency,
      signDisplay: sign ? "exceptZero" : "auto",
      ...(compact ? { notation: "compact", maximumFractionDigits: 1 } : {}),
      ...(whole ? { minimumFractionDigits: 0, maximumFractionDigits: 0 } : {}),
    });
    formatters.set(key, f);
  }
  return f.format(cents / 100);
}

/**
 * Parses an amount as typed or exported: "12", "12.5", "12,50", "1.234,56", "1,234.56",
 * "-3,20 €", "(45.00)". The decimal separator is the last "," or "." followed by one or two
 * digits at the end, unless `decimal` says which one it is. Returns cents, or null.
 */
export function parseMoney(input: string, decimal?: "," | "."): number | null {
  let s = input.trim().replace(/[\s '’]/g, "").replace(/[^\d,.\-+()]/g, "");
  if (!s) return null;
  let negative = false;
  if (/^\(.*\)$/.test(s)) {
    negative = true;
    s = s.slice(1, -1);
  }
  if (s.startsWith("-") || s.startsWith("+")) {
    negative = negative || s[0] === "-";
    s = s.slice(1);
  } else if (s.endsWith("-")) {
    negative = true; // "12,50-" (some banks)
    s = s.slice(0, -1);
  }
  const sep = decimal ??
    (/[,.]\d{1,2}$/.exec(s)?.[0][0] as "," | "." | undefined);
  let int = s, frac = "";
  if (sep) {
    const i = s.lastIndexOf(sep);
    if (i >= 0) {
      int = s.slice(0, i);
      frac = s.slice(i + 1);
    }
  }
  int = int.replace(/[,.]/g, "");
  if (!/^\d*$/.test(int) || !/^\d{0,2}$/.test(frac) || (!int && !frac)) {
    return null;
  }
  const cents = Number(int || "0") * 100 + Number(frac.padEnd(2, "0") || "0");
  return negative ? -cents : cents;
}

/** Cents as an editable string in the language's style, without currency: "1234,56". */
export function centsToInput(cents: number, lang: string): string {
  const s = (Math.abs(cents) / 100).toFixed(2);
  return lang === "de" ? s.replace(".", ",") : s;
}
