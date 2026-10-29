"use client";

// The calendar page: year grid (month view on phones), type chips, coverage, selection bar,
// notes, keyboard shortcuts and clipboard. Ported from family-planner's VacationPage.tsx.

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { ChevronLeft, ChevronRight, CircleHelp, Redo2, Rss, Undo2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { cn } from "@/lib/utils";
import { PlannerProvider, useMedia, useMounted, usePlanner } from "./context";
import { Coverage } from "./coverage";
import { type GridView, monthView } from "./grid";
import { HelpDialog } from "./help-dialog";
import { NoteDialog } from "./note-dialog";
import { todayIso } from "./planner-store";
import { SelectionBar } from "./selection-bar";
import { TypeChips } from "./type-chips";
import { zoomBy } from "./view-prefs";
import { YearGrid } from "./year-grid";

function inEditable(e: Event) {
  const el = e.target;
  return (
    el instanceof HTMLInputElement ||
    el instanceof HTMLSelectElement ||
    el instanceof HTMLTextAreaElement ||
    (el instanceof HTMLElement && el.isContentEditable) ||
    !!document.querySelector('[role="dialog"], [role="alertdialog"]')
  );
}

/** Keeps the shown year in the address (?y=) without a server round trip. */
function rememberYear(y: number) {
  const url = new URL(window.location.href);
  url.searchParams.set("y", String(y));
  window.history.replaceState(window.history.state, "", url);
}

export function CalendarPage({ familyId, year, readOnly }: { familyId: string; year: number; readOnly: boolean }) {
  const mounted = useMounted();
  const { t } = useT();
  if (!mounted) {
    return (
      <div className="space-y-3" aria-busy="true">
        <h1 className="text-2xl font-semibold tracking-tight">{t("nav.calendar")}</h1>
        <Skeleton className="h-9 w-full max-w-md" />
        <Skeleton className="h-[60vh] w-full" />
      </div>
    );
  }
  return (
    <PlannerProvider familyId={familyId} year={year} readOnly={readOnly}>
      <Planner />
    </PlannerProvider>
  );
}

function Planner() {
  const { t } = useT();
  const store = usePlanner();
  const narrow = useMedia("(max-width: 640px)");
  const plannerRef = useRef<HTMLDivElement>(null);
  const dockRef = useRef<HTMLDivElement>(null);
  const gridRef = useRef<GridView | null>(null);
  const [fill, setFill] = useState<number | null>(null);
  const [noteDays, setNoteDays] = useState<string[] | null>(null);
  const [helpOpen, setHelpOpen] = useState(false);
  const centered = useRef(false);

  const openNote = useCallback(() => {
    if (store.readOnly) return;
    const days = store.targetDays();
    if (!days.length) return void toast(t("calendar.toast.selectFirst"));
    setNoteDays(days);
  }, [store, t]);

  const jumpToGap = useCallback(() => {
    const day = store.nextGap();
    if (day) gridRef.current?.centerOn(day);
  }, [store]);

  const setYear = useCallback(
    (y: number) => {
      store.setYear(y);
      rememberYear(store.year);
    },
    [store],
  );

  // Once the family has loaded, show today in the middle.
  useEffect(() => {
    if (centered.current || !store.family || !gridRef.current) return;
    centered.current = true;
    const today = todayIso();
    if (String(store.year) === today.slice(0, 4)) gridRef.current.centerOn(today);
  });

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const mod = e.ctrlKey || e.metaKey;
      const dialog = document.querySelector('[role="dialog"], [role="alertdialog"]');
      // Zooms the calendar instead of the page, also while a field has the focus.
      const zoom = ({ "+": 1, "=": 1, "-": -1, "0": 0 } as Record<string, number>)[e.key];
      if (mod && !e.altKey && zoom !== undefined && !dialog) {
        if (monthView()) return;
        e.preventDefault();
        zoomBy(zoom);
        return;
      }
      if (inEditable(e)) return;
      const week = monthView() ? 7 : 31; // up/down: a week in the month view, else a month
      const arrows: Record<string, number> = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -week, ArrowDown: week };
      const key = e.key.toLowerCase();
      if (e.key in arrows) {
        e.preventDefault();
        const day = store.moveFocus(arrows[e.key], e.shiftKey);
        if (day) gridRef.current?.scrollTo(day);
      } else if (e.key === "Escape") {
        if (gridRef.current?.cancelFill()) return;
        store.deselect();
      } else if (e.key === "PageUp") {
        e.preventDefault();
        setYear(store.year - 1);
      } else if (e.key === "PageDown") {
        e.preventDefault();
        setYear(store.year + 1);
      } else if (mod && key === "z") {
        e.preventDefault();
        if (store.readOnly) return;
        if (e.shiftKey) store.redo();
        else store.undo();
      } else if (mod && key === "y") {
        e.preventDefault();
        if (!store.readOnly) store.redo();
      } else if (mod && key === "a") {
        e.preventDefault();
        store.select(`${store.year}-01-01`, `${store.year}-12-31`);
      } else if (mod || e.altKey) {
        return; // copy / cut / paste are handled by the clipboard events; Ctrl/⌘+J and +B by the shell
      } else if (e.key === "Delete" || e.key === "Backspace") {
        e.preventDefault();
        store.clearSelectedDays();
      } else if (/^[1-9]$/.test(e.key)) {
        const type = store.types[Number(e.key) - 1];
        if (type) store.toggleOnSelection(type.id);
      } else if (e.key === "?") {
        setHelpOpen(true);
      } else if (key === "g") {
        jumpToGap();
      } else if (key === "n" && !e.shiftKey) {
        e.preventDefault();
        openNote();
      }
    };
    const onCopy = (e: ClipboardEvent, cut = false) => {
      if (inEditable(e) || !store.selection.size) return;
      const text = store.copySelection();
      if (!text) return;
      e.clipboardData?.setData("text/plain", text);
      e.preventDefault();
      if (cut) store.clearSelectedDays();
    };
    const copy = (e: ClipboardEvent) => onCopy(e);
    const cut = (e: ClipboardEvent) => !store.readOnly && onCopy(e, true);
    const paste = (e: ClipboardEvent) => {
      if (inEditable(e) || store.readOnly) return;
      e.preventDefault();
      store.pasteText(e.clipboardData?.getData("text/plain") ?? "");
    };
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("copy", copy);
    document.addEventListener("cut", cut);
    document.addEventListener("paste", paste);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("copy", copy);
      document.removeEventListener("cut", cut);
      document.removeEventListener("paste", paste);
    };
  });

  const callbacks = {
    onNote: openNote,
    onFill: setFill,
    dockTop: () => dockRef.current?.getBoundingClientRect().top ?? innerHeight,
  };
  const onReady = useCallback((g: GridView | null) => {
    gridRef.current = g;
  }, []);

  if (store.notFound) {
    return <p className="text-sm text-muted-foreground">{t("calendar.notFound")}</p>;
  }

  const sync = store.sync;
  const showSync = sync.key === "saving" || sync.key === "retrying" || sync.key === "offline" || sync.key === "loading";

  return (
    <>
      <div className="mb-3 flex flex-wrap items-center gap-x-2 gap-y-2">
        <h1 className="mr-1 text-2xl font-semibold tracking-tight">{t("nav.calendar")}</h1>
        <YearNav year={store.year} onChange={setYear} />
        {showSync && (
          <span className={cn("text-xs text-muted-foreground", sync.error && "text-destructive")} aria-live="polite">
            {t(`calendar.sync.${sync.key}`)}
          </span>
        )}
        <div className="flex-1" />
        {!store.readOnly && (
          <>
            <Button
              variant="ghost"
              size="icon"
              title={t("calendar.toolbar.undoTitle")}
              aria-label={t("calendar.toolbar.undo")}
              disabled={!store.undoStack.length}
              onClick={() => store.undo()}
            >
              <Undo2 />
            </Button>
            <Button
              variant="ghost"
              size="icon"
              title={t("calendar.toolbar.redoTitle")}
              aria-label={t("calendar.toolbar.redo")}
              disabled={!store.redoStack.length}
              onClick={() => store.redo()}
            >
              <Redo2 />
            </Button>
          </>
        )}
        <Button
          variant="ghost"
          size="icon"
          title={t("calendar.toolbar.help")}
          aria-label={t("calendar.toolbar.help")}
          onClick={() => setHelpOpen(true)}
        >
          <CircleHelp />
        </Button>
        <Button variant="outline" size="sm" asChild title={t("calendar.toolbar.feed")}>
          <Link href={`/f/${store.familyId}/settings?tab=feed`}>
            <Rss /> <span className="max-sm:sr-only">{t("calendar.toolbar.feed")}</span>
          </Link>
        </Button>
      </div>
      <div
        ref={plannerRef}
        className="planner flex min-w-0 flex-col max-sm:-mx-4"
        style={{ "--mv-top": "calc(3.5rem + 1px)" } as React.CSSProperties}
      >
        {!narrow && (
          <div className="mb-3 flex items-start gap-3">
            <TypeChips className="flex-1 flex-wrap" />
            <Coverage onJump={jumpToGap} />
          </div>
        )}
        {narrow && <Coverage onJump={jumpToGap} className="mx-3 mt-1 mb-2 justify-between self-stretch" />}
        {store.readOnly && store.family && (
          <p className="mx-3 mb-3 rounded-lg border border-primary/20 bg-primary/5 px-3 py-2 text-sm sm:mx-0">
            {t("calendar.readonly")}
          </p>
        )}
        <YearGrid plannerRef={plannerRef} callbacks={callbacks} onReady={onReady} />
        {!narrow && (
          <div className="mt-2.5">
            <SelectionBar fill={fill} onNote={openNote} />
          </div>
        )}
      </div>
      {narrow && (
        <div
          ref={dockRef}
          className="sticky bottom-0 z-10 -mx-4 -mb-6 border-t bg-card/90 pt-2 pb-[max(8px,env(safe-area-inset-bottom))] shadow-[0_-8px_24px_rgba(0,0,0,0.1)] backdrop-blur-lg"
        >
          <div className="mb-2">
            <SelectionBar fill={fill} onNote={openNote} compact />
          </div>
          <TypeChips className="overflow-x-auto px-3 py-0.5 [scrollbar-width:none]" />
        </div>
      )}
      {noteDays && <NoteDialog days={noteDays} onClose={() => setNoteDays(null)} />}
      <HelpDialog open={helpOpen} onOpenChange={setHelpOpen} />
    </>
  );
}

function YearNav({ year, onChange }: { year: number; onChange: (y: number) => void }) {
  const { t } = useT();
  const now = new Date().getFullYear();
  const years = new Set<number>();
  for (let y = now - 5; y <= now + 5; y++) years.add(y);
  years.add(year);
  // On phones the arrows are hidden; the year list does the same.
  return (
    <div className="flex items-center gap-0.5">
      <Button
        variant="ghost"
        size="icon"
        className="max-sm:hidden"
        title={t("calendar.year.prevTitle")}
        aria-label={t("calendar.year.prev")}
        onClick={() => onChange(year - 1)}
      >
        <ChevronLeft />
      </Button>
      <select
        className="h-9 w-[92px] rounded-md border border-input bg-background pr-8 pl-3 text-sm font-semibold"
        aria-label={t("calendar.year.label")}
        value={year}
        onChange={(e) => onChange(Number(e.target.value))}
      >
        {[...years]
          .sort((a, b) => a - b)
          .map((y) => (
            <option key={y} value={y}>
              {y}
            </option>
          ))}
      </select>
      <Button
        variant="ghost"
        size="icon"
        className="max-sm:hidden"
        title={t("calendar.year.nextTitle")}
        aria-label={t("calendar.year.next")}
        onClick={() => onChange(year + 1)}
      >
        <ChevronRight />
      </Button>
    </div>
  );
}
