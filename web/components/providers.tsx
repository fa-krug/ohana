"use client";

import { I18nProvider } from "@/lib/i18n/provider";
import { Toaster } from "@/components/ui/sonner";
import type { Locale } from "@/lib/i18n/config";
import type { Dictionary } from "@/lib/i18n/translate";

export function Providers({
  locale,
  dicts,
  children,
}: {
  locale: Locale;
  dicts: Record<Locale, Dictionary>;
  children: React.ReactNode;
}) {
  return (
    <I18nProvider locale={locale} dicts={dicts}>
      {children}
      <Toaster />
    </I18nProvider>
  );
}
