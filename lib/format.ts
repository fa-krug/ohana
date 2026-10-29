/** A date (and optionally time) in the user's language, e.g. "1 Nov 2026". */
export function formatDate(date: Date | string, locale: string, withTime = false): string {
  return new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", {
    dateStyle: "medium",
    ...(withTime ? { timeStyle: "short" } : {}),
  }).format(new Date(date));
}
