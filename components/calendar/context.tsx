"use client";

import { createContext, useContext, useEffect, useState, useSyncExternalStore } from "react";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { moduleOf, useAssistantChanges } from "@/components/assistant/events";
import { PlannerStore } from "./planner-store";

const PlannerContext = createContext<PlannerStore | null>(null);

/** One PlannerStore for the family's calendar while the page is open: loads the year and
 *  polls for other people's changes. */
export function PlannerProvider({
  familyId,
  year,
  readOnly,
  children,
}: {
  familyId: string;
  year: number;
  readOnly: boolean;
  children: React.ReactNode;
}) {
  const { t, tList, locale } = useT();
  const [store] = useState(
    () => new PlannerStore(familyId, year, { readOnly, i18n: { t, tList, locale }, toast: (msg) => toast(msg) }),
  );
  // After every render: the dictionary functions are new each time; a language switch makes
  // the grid rebuild its month and weekday names.
  useEffect(() => store.setI18n({ t, tList, locale }));
  useEffect(() => {
    void store.open();
    // Closing or reloading the page while changes are still being saved asks first.
    const unload = (e: BeforeUnloadEvent) => {
      if (store.pending) e.preventDefault();
    };
    window.addEventListener("beforeunload", unload);
    return () => {
      window.removeEventListener("beforeunload", unload);
      store.close();
    };
  }, [store]);
  // The assistant changed the calendar: it reloads (after the changes of its own are saved).
  useAssistantChanges(familyId, (kind) => {
    if (moduleOf(kind) === "calendar") void store.load({ quiet: true });
  });
  return <PlannerContext.Provider value={store}>{children}</PlannerContext.Provider>;
}

/** The store without subscribing (for callbacks). */
export function usePlannerStore(): PlannerStore {
  const store = useContext(PlannerContext);
  if (!store) throw new Error("usePlannerStore must be used within a PlannerProvider");
  return store;
}

/** The store, re-rendering on each of its changes. */
export function usePlanner(): PlannerStore {
  const store = usePlannerStore();
  useSyncExternalStore(store.subscribe, store.getRev, store.getRev);
  return store;
}

/** A media query, false on the server and until mounted. */
export function useMedia(query: string): boolean {
  return useSyncExternalStore(
    (fn) => {
      const mq = matchMedia(query);
      mq.addEventListener("change", fn);
      return () => mq.removeEventListener("change", fn);
    },
    () => matchMedia(query).matches,
    () => false,
  );
}

/** True once mounted: the calendar is drawn in the browser only (it measures the screen and
 *  reads per-device settings). */
export function useMounted(): boolean {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  return mounted;
}
