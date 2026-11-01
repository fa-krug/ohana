export const locales = ["en", "de"] as const;
export type Locale = (typeof locales)[number];
/** The languages of texts the server writes (presets, notifications, the assistant). */
export type Lang = Locale;
export const defaultLocale: Locale = "en";

export function isLocale(x: string | null | undefined): x is Locale {
  return x != null && (locales as readonly string[]).includes(x);
}
