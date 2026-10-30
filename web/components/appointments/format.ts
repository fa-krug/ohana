/** A slot's date and time in the user's language. */
export function formatSlot(iso: string, locale: string, style: "medium" | "full" = "medium"): string {
  return new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", { dateStyle: style, timeStyle: "short" }).format(new Date(iso));
}
