"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

/** Soft-refreshes the route on an interval (while the tab is visible), so runs made by
 *  the worker show up without a reload. */
export function useAutoRefresh(intervalMs = 45000): void {
  const router = useRouter();
  useEffect(() => {
    const id = setInterval(() => {
      if (document.visibilityState === "visible") router.refresh();
    }, intervalMs);
    return () => clearInterval(id);
  }, [router, intervalMs]);
}

/** Every 3 s while something is queued or running, else every 45 s. */
export function useRunRefresh(busy: boolean): void {
  useAutoRefresh(busy ? 3000 : 45000);
}
