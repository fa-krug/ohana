"use client";

import { createContext, useContext, useEffect, useState, useSyncExternalStore } from "react";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { moduleOf, useAssistantChanges } from "@/components/assistant/events";
import { FinanceStore } from "./finance-store";

const FinanceContext = createContext<FinanceStore | null>(null);

/** One FinanceStore for the family's finances while the page is open. */
export function FinanceProvider({
  familyId,
  readOnly,
  children,
}: {
  familyId: string;
  readOnly: boolean;
  children: React.ReactNode;
}) {
  const { t, locale } = useT();
  const [store] = useState(
    () =>
      new FinanceStore(familyId, {
        readOnly,
        i18n: { t, locale },
        toast: (message, action) => toast(message, action ? { action } : undefined),
      }),
  );
  // The dictionary functions are new on each render (a language switch).
  useEffect(() => store.setI18n({ t, locale }));
  // The assistant changed the finances: what is shown reloads.
  useAssistantChanges(familyId, (kind) => {
    if (moduleOf(kind) !== "finance") return;
    if (kind === "transactions") store.refresh();
    else store.refreshCategories();
  });
  return <FinanceContext.Provider value={store}>{children}</FinanceContext.Provider>;
}

/** The store without subscribing (for callbacks). */
export function useFinanceStore(): FinanceStore {
  const store = useContext(FinanceContext);
  if (!store) throw new Error("useFinanceStore must be used within a FinanceProvider");
  return store;
}

/** The store, re-rendering on each of its changes. */
export function useFinance(): FinanceStore {
  const store = useFinanceStore();
  useSyncExternalStore(store.subscribe, store.getRev, store.getRev);
  return store;
}
