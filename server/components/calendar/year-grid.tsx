"use client";

import { useEffect, useRef } from "react";
import { useT } from "@/lib/i18n/provider";
import { usePlannerStore } from "./context";
import { type GridCallbacks, GridView } from "./grid";
import "./calendar.css";

/** Mounts the imperative calendar (grid.ts) and hands its GridView to the page. */
export function YearGrid({
  plannerRef,
  callbacks,
  onReady,
}: {
  plannerRef: React.RefObject<HTMLElement | null>;
  callbacks: GridCallbacks;
  onReady: (grid: GridView | null) => void;
}) {
  const { t } = useT();
  const store = usePlannerStore();
  const wrapRef = useRef<HTMLDivElement>(null);
  const gridRef = useRef<HTMLDivElement>(null);
  const cb = useRef(callbacks);
  useEffect(() => {
    cb.current = callbacks;
  });

  useEffect(() => {
    const view = new GridView(store, wrapRef.current!, gridRef.current!, plannerRef.current!, {
      onNote: () => cb.current.onNote(),
      onFill: (n) => cb.current.onFill(n),
      dockTop: () => cb.current.dockTop(),
    });
    onReady(view);
    return () => {
      view.destroy();
      onReady(null);
    };
    // The view lives as long as the store; callbacks go through the ref.
  }, [store, plannerRef, onReady]);

  return (
    <div ref={wrapRef} className="grid-wrap">
      <div ref={gridRef} className="grid" role="grid" tabIndex={0} aria-label={t("calendar.gridLabel")} />
    </div>
  );
}
