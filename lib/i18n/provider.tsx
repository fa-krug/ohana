"use client";

import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { translate, translateList, type Dictionary, type TVars } from "./translate";
import { locales, type Locale } from "./config";
import { updateProfileAction } from "@/app/actions/account";

type Ctx = {
  locale: Locale;
  dict: Dictionary;
  setLocale: (next: Locale) => void;
};
const I18nContext = createContext<Ctx | null>(null);

export function I18nProvider({
  locale,
  dicts,
  children,
}: {
  locale: Locale;
  dicts: Record<Locale, Dictionary>;
  children: React.ReactNode;
}) {
  const [current, setCurrent] = useState<Locale>(locale);

  // Keep in sync if the server-resolved locale changes across navigations.
  useEffect(() => setCurrent(locale), [locale]);

  const setLocale = useCallback((next: Locale) => {
    if (!locales.includes(next)) return;
    setCurrent(next); // instant, client-side
    // Persist in the background; no page reload.
    void updateProfileAction({ preferredLanguage: next });
    void fetch("/set-language", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ lang: next }),
    });
  }, []);

  const value: Ctx = { locale: current, dict: dicts[current], setLocale };
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useT() {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error("useT must be used within an I18nProvider");
  return {
    locale: ctx.locale,
    setLocale: ctx.setLocale,
    t: (key: string, vars?: TVars) => translate(ctx.dict, key, vars),
    tList: (key: string) => translateList(ctx.dict, key),
  };
}
