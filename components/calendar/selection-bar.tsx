"use client";

import { useEffect, useState } from "react";
import { CalendarRange, Eraser, MessageCircle, MousePointerClick, Search, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { isWeekend } from "@/lib/calendar/core";
import { useT } from "@/lib/i18n/provider";
import { cn } from "@/lib/utils";
import { useMedia, usePlanner } from "./context";
import { birthdayText, eventText, fmtDate, noteText } from "./grid";
import { readFlag, setZoom, useViewPrefs, writeFlag, ZOOM } from "./view-prefs";

const HINTED_KEY = "ohana.calendar.hinted";

/** A hint while nothing is selected; the selection and its actions otherwise. On phones it
 *  sits in the dock at the bottom. */
export function SelectionBar({
  fill,
  onNote,
  compact,
}: {
  fill: number | null;
  onNote: () => void;
  compact?: boolean;
}) {
  const { t, locale } = useT();
  const store = usePlanner();
  const coarse = useMedia("(pointer: coarse)");
  const { readOnly } = store;
  const days = store.selectedDays();
  const has = days.length > 0;
  // Phones show the "how to select" hint only until the first selection.
  const [hinted, setHinted] = useState(true);
  useEffect(() => setHinted(readFlag(HINTED_KEY)), []);
  useEffect(() => {
    if (has && !hinted) {
      writeFlag(HINTED_KEY, true);
      setHinted(true);
    }
  }, [has, hinted]);

  let info: string;
  // A single day's timed events (booked appointments) and birthdays; on phones on a line of
  // their own.
  let eventLine = "";
  if (fill !== null) {
    info = fill
      ? t("calendar.fill.count", { days: t("calendar.count.days", { count: fill }) })
      : t("calendar.fill.dragPast");
  } else if (!has) {
    info = readOnly ? t("calendar.sel.viewOnly") : coarse ? t("calendar.sel.noneTouch") : t("calendar.sel.none");
  } else {
    const work = days.filter((d) => !isWeekend(d)).length;
    const span =
      days.length === 1
        ? fmtDate(locale, days[0])
        : `${fmtDate(locale, days[0])} – ${fmtDate(locale, days[days.length - 1])}`;
    // Touch devices have no tooltips, so a single day's note is shown here.
    const note = days.length === 1 && store.notes.get(days[0]);
    const events = days.length === 1 ? (store.events.get(days[0]) ?? []) : [];
    info =
      t("calendar.sel.info", {
        days: t("calendar.count.days", { count: days.length }),
        weekdays: t("calendar.count.weekdays", { count: work }),
        span,
      }) +
      (note ? " · " + noteText(note) : "");
    const birthdays = days.length === 1 ? (store.birthdays.get(days[0]) ?? []) : [];
    eventLine = [...events.map((e) => "🕑 " + eventText(e)), ...birthdays.map((b) => birthdayText(t, b))].join(" · ");
    if (eventLine && !compact) {
      info += " · " + eventLine;
      eventLine = "";
    }
  }

  if (compact && !has && fill === null && (hinted || readOnly)) return null;

  return (
    <div
      className={cn(
        "flex min-h-[46px] items-center gap-2.5 rounded-lg border border-transparent py-1.5 pr-1.5 pl-3.5 text-[13px] text-muted-foreground max-sm:text-sm",
        has && !compact && "border-border bg-card shadow-xs",
        compact && "min-h-0 flex-wrap gap-x-2 gap-y-1.5 py-0 pr-2",
      )}
    >
      <span className={cn("min-w-0 flex-1 truncate", has && "font-medium text-foreground")}>{info}</span>
      {eventLine && <span className="order-2 basis-full truncate text-foreground">{eventLine}</span>}
      {has && !readOnly && (
        <div
          className={cn(
            "flex items-center gap-2 text-foreground",
            compact && "order-3 -mr-2 -ml-3.5 basis-full overflow-x-auto px-3 [scrollbar-width:none]",
          )}
        >
          <Button size="sm" variant="outline" title={t("calendar.toolbar.noteTitle")} onClick={onNote}>
            <MessageCircle /> {t("calendar.toolbar.note")}
          </Button>
          <Button
            size="sm"
            variant="outline"
            title={t("calendar.sel.clearTitle")}
            onClick={() => store.clearSelectedDays()}
          >
            <Eraser /> {t("calendar.sel.clear")}
          </Button>
          <label
            className="mx-1.5 inline-flex shrink-0 cursor-pointer items-center gap-2 whitespace-nowrap select-none"
            title={t("calendar.toolbar.skipWeekendsTitle")}
          >
            <Checkbox checked={store.skipWeekends} onCheckedChange={(v) => store.setSkipWeekends(!!v)} />
            {t("calendar.toolbar.skipWeekends")}
          </label>
          {coarse && (
            <>
              <Button
                size="sm"
                variant={store.rangeMode ? "secondary" : "outline"}
                aria-pressed={store.rangeMode}
                title={t("calendar.toolbar.rangeTitle")}
                onClick={() => store.setRangeMode(!store.rangeMode)}
              >
                <CalendarRange /> {t("calendar.toolbar.range")}
              </Button>
              <Button
                size="sm"
                variant={store.multi ? "secondary" : "outline"}
                aria-pressed={store.multi}
                title={t("calendar.toolbar.multiTitle")}
                onClick={() => store.setMulti(!store.multi)}
              >
                <MousePointerClick /> {t("calendar.toolbar.multi")}
              </Button>
            </>
          )}
        </div>
      )}
      {has && (
        <Button
          size="icon"
          variant="ghost"
          className="size-8"
          title={t("calendar.sel.deselectTitle")}
          aria-label={t("calendar.sel.deselect")}
          onClick={() => store.deselect()}
        >
          <X />
        </Button>
      )}
      {!compact && <ZoomSlider />}
    </div>
  );
}

function ZoomSlider() {
  const { t } = useT();
  const { zoom } = useViewPrefs();
  return (
    <label className="ml-2 inline-flex items-center gap-1.5 select-none" title={t("calendar.toolbar.zoomTitle")}>
      <Search className="size-3.5 opacity-70" aria-hidden />
      <input
        type="range"
        className="w-24 cursor-pointer accent-primary"
        aria-label={t("calendar.toolbar.zoom")}
        min={ZOOM.min}
        max={ZOOM.max}
        // To the right = zoom in = fewer days.
        value={ZOOM.min + ZOOM.max - zoom}
        onChange={(e) => setZoom(ZOOM.min + ZOOM.max - Number(e.target.value))}
      />
      <output className="min-w-[4.2em] tabular-nums">{t("calendar.toolbar.zoomDays", { count: zoom })}</output>
    </label>
  );
}
