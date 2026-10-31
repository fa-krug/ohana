"use client";

// The assistant changed something (or a change of it was undone): the pages that show it
// reload. The panel lives in the app shell, the pages have their own stores, so they meet
// through a window event.

import { useEffect, useRef } from "react";

const EVENT = "ohana:assistant-change";

export interface ChangeDetail {
  familyId: string;
  /** What changed: entries | notes | types | events | categories | transactions | benchmark |
   *  recipes | plan | shopping | appointments */
  kind: string;
}

export function notifyChanged(familyId: string, kind: string): void {
  window.dispatchEvent(new CustomEvent<ChangeDetail>(EVENT, { detail: { familyId, kind } }));
}

/** Calls `fn` when the assistant changed something of the family. */
export function useAssistantChanges(familyId: string, fn: (kind: string) => void): void {
  const ref = useRef(fn);
  useEffect(() => {
    ref.current = fn;
  });
  useEffect(() => {
    const listener = (e: Event) => {
      const detail = (e as CustomEvent<ChangeDetail>).detail;
      if (detail?.familyId === familyId) ref.current(detail.kind);
    };
    window.addEventListener(EVENT, listener);
    return () => window.removeEventListener(EVENT, listener);
  }, [familyId]);
}

/** Which module's data a change touches. */
export function moduleOf(kind: string): "calendar" | "finance" | "meals" | "appointments" | "other" {
  if (kind === "entries" || kind === "notes" || kind === "types" || kind === "events") return "calendar";
  if (kind === "recipes" || kind === "plan" || kind === "shopping") return "meals";
  if (kind === "appointments") return "appointments";
  if (kind === "categories" || kind === "transactions" || kind === "benchmark") return "finance";
  return "other";
}
