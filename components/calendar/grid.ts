// The calendar itself, drawn without React: 12 × 31 day cells (or 12 month calendars on
// phones), updated in place from the PlannerStore, with mouse / touch selection, the ▪ fill
// handle and the zoom. Performance-sensitive, so it stays imperative; year-grid.tsx mounts it.
// Ported from family-planner's app/src/features/vacation/grid.ts.

import {
  addDays,
  contrastText,
  daysInMonth,
  fillWith,
  isGap,
  iso,
  isWeekend,
  type Note,
  patternOf,
  range,
  roleMap,
  weekday,
} from "@/lib/calendar/core";
import { type Change, type PlannerStore, todayIso } from "./planner-store";
import { SHOW_WEEKDAYS, subscribeViewPrefs, viewPrefs } from "./view-prefs";

const LONG_PRESS_MS = 350;
const LONG_DATE: Intl.DateTimeFormatOptions = {
  weekday: "long",
  day: "numeric",
  month: "long",
  year: "numeric",
};
let narrow: MediaQueryList | null = null;
/** Phones (the month view); a function, since there is no matchMedia on the server. */
export function narrowScreen(): MediaQueryList {
  return (narrow ??= matchMedia("(max-width: 640px)"));
}

const formatters = new Map<string, Intl.DateTimeFormat>(); // slow to create; reuse per language

export function fmtDate(
  locale: string,
  d: string,
  opts: Intl.DateTimeFormatOptions = {
    weekday: "short",
    day: "numeric",
    month: "short",
  },
) {
  const key = locale + JSON.stringify(opts);
  if (!formatters.has(key)) {
    formatters.set(key, new Intl.DateTimeFormat(locale, opts));
  }
  return formatters.get(key)!.format(new Date(d + "T00:00:00"));
}

export function noteText(note: Note) {
  return [note.icon, note.comment].filter(Boolean).join(" ");
}

/** Phones show one calendar per month (7 columns) instead of the 12 × 31 year grid. */
export function monthView() {
  return narrowScreen().matches;
}

type Drag =
  | { mode: "tap"; date: string; x: number; y: number; timer: number }
  | {
      mode: "select";
      anchor: string;
      base: Set<string>;
      last: string;
      touch?: boolean;
      x?: number;
      y?: number;
    }
  | {
      mode: "fill";
      src: string[];
      targets: string[];
      backwards?: boolean;
      last?: string;
      pointerId: number;
    };

export interface GridCallbacks {
  /** Double click on a day: open the note dialog for it. */
  onNote(): void;
  /** While dragging the fill handle: how many days it fills (null when done). */
  onFill(n: number | null): void;
  /** Top of the bottom dock on phones, for scrolling while selecting a range by touch. */
  dockTop(): number;
}

export class GridView {
  private cells = new Map<string, HTMLElement>();
  private cellSigs = new WeakMap<HTMLElement, string>();
  private cellTypesSig: string | null = null;
  private shownSel = new Set<string>();
  private shownFocus: string | null = null;
  private previewed = new Set<string>();
  private fillHandle = Object.assign(document.createElement("i"), {
    className: "fill-handle",
  });
  private drag: Drag | null = null;
  private lastPointer = "mouse";
  private edgeScrolling = false;
  private builtFor = "";
  private cleanup: (() => void)[] = [];
  private today = todayIso();

  constructor(
    private store: PlannerStore,
    private wrap: HTMLElement,
    private grid: HTMLElement,
    private planner: HTMLElement,
    private cb: GridCallbacks,
  ) {
    this.cleanup.push(store.subscribe((c) => this.onChange(c)));
    this.cleanup.push(subscribeViewPrefs(() => this.applyZoom()));
    const fit = new ResizeObserver(() => this.fitWindow());
    fit.observe(planner);
    this.cleanup.push(() => fit.disconnect());
    const layout = () => {
      this.applyZoom({ keepView: false });
      this.render();
      this.centerOn(store.focus ?? this.today);
    };
    narrowScreen().addEventListener("change", layout);
    this.cleanup.push(() => narrowScreen().removeEventListener("change", layout));
    this.bindPointer();
    this.applyZoom({ keepView: false });
    this.render();
  }

  destroy() {
    for (const fn of this.cleanup) fn();
    this.store.dragging = false;
  }

  private onChange(change: Change) {
    if (change === "selection") this.renderSelection();
    else this.render();
  }

  cellFor(date: string | null) {
    return date ? this.cells.get(date) : undefined;
  }

  // ------------------------------------------------------------- building

  /** Rebuilds the cells when the year, the layout or the language changed. */
  render() {
    const key = `${this.store.year}|${monthView() ? "months" : "year"}|${this.store.i18n.locale}`;
    if (key !== this.builtFor) this.build(key);
    this.planner.classList.toggle("readonly", this.store.readOnly);
    this.renderCells();
    this.renderSelection();
  }

  /** Forces a rebuild, e.g. after a language switch. */
  rebuild() {
    this.builtFor = "";
    this.render();
  }

  private build(key: string) {
    this.grid.textContent = "";
    this.cells = new Map();
    this.cellSigs = new WeakMap();
    this.fillHandle.title = this.store.i18n.t("calendar.fill.handle");
    this.shownSel = new Set();
    this.shownFocus = null;
    this.previewed = new Set();
    const months = monthView();
    this.grid.classList.toggle("yv", !months);
    this.grid.classList.toggle("mv", months);
    this.grid.append(months ? this.buildMonths() : this.buildYear());
    this.builtFor = key;
  }

  /** A day cell; `label` is its weekday letter (year grid) or day number (month view). */
  private makeCell(date: string, label: string | number) {
    const cell = document.createElement("div");
    cell.className = "cell";
    cell.setAttribute("role", "gridcell");
    cell.dataset.date = date;
    const wd = document.createElement("span");
    wd.className = "wd";
    wd.textContent = String(label);
    const fills = document.createElement("div");
    fills.className = "fills";
    const icon = document.createElement("span");
    icon.className = "note-icon";
    const mark = document.createElement("span");
    mark.className = "note-mark";
    const overlay = document.createElement("div");
    overlay.className = "sel-overlay";
    cell.append(fills, wd, icon, mark, overlay);
    if (isWeekend(date)) cell.classList.add("weekend");
    if (date === this.today) cell.classList.add("today");
    this.cells.set(date, cell);
    return cell;
  }

  /** Wide screens: 12 month rows × 31 day columns. */
  private buildYear() {
    const year = this.store.year;
    const frag = document.createDocumentFragment();
    const corner = document.createElement("div");
    corner.className = "head corner";
    frag.append(corner);
    const [ty, tm, td] = this.today.split("-").map(Number);
    const thisYear = ty === year;
    for (let d = 1; d <= 31; d++) {
      const h = document.createElement("div");
      h.className = "head";
      h.classList.toggle("is-today", thisYear && d === td);
      h.textContent = String(d);
      frag.append(h);
    }
    const months = this.store.i18n.tList("calendar.months");
    const weekdays = this.store.i18n.tList("calendar.weekdayLetters");
    for (let m = 0; m < 12; m++) {
      const label = document.createElement("div");
      label.className = "month";
      label.classList.toggle("is-today", thisYear && m === tm - 1);
      label.textContent = months[m];
      frag.append(label);
      const n = daysInMonth(year, m);
      for (let d = 1; d <= 31; d++) {
        if (d > n) {
          const cell = document.createElement("div");
          cell.className = "cell invalid";
          cell.setAttribute("role", "gridcell");
          frag.append(cell);
        } else {
          const date = iso(year, m, d);
          frag.append(this.makeCell(date, weekdays[weekday(date)]));
        }
      }
    }
    return frag;
  }

  /** Phones: one calendar per month, weeks from Monday to Sunday, scrolling with the page. */
  private buildMonths() {
    const year = this.store.year;
    const frag = document.createDocumentFragment();
    const names = Array.from(
      { length: 7 },
      (_, i) => fmtDate(this.store.i18n.locale, iso(2024, 0, 1 + i), { weekday: "short" }), // Jan 1, 2024 was a Monday
    );
    for (let m = 0; m < 12; m++) {
      const first = iso(year, m, 1);
      const section = document.createElement("section");
      section.className = "mv-month";
      section.classList.toggle("is-today", first.slice(0, 7) === this.today.slice(0, 7));
      const title = document.createElement("h3");
      title.className = "mv-title";
      title.textContent = fmtDate(this.store.i18n.locale, first, { month: "long", year: "numeric" });
      const days = document.createElement("div");
      days.className = "mv-days";
      for (const name of names) {
        const h = document.createElement("div");
        h.className = "mv-wd";
        h.textContent = name;
        days.append(h);
      }
      for (let i = (weekday(first) + 6) % 7; i > 0; i--) {
        days.append(
          Object.assign(document.createElement("div"), {
            className: "mv-blank",
          }),
        );
      }
      for (let d = 1; d <= daysInMonth(year, m); d++) {
        days.append(this.makeCell(iso(year, m, d), d));
      }
      section.append(title, days);
      frag.append(section);
    }
    return frag;
  }

  // ------------------------------------------------------------- rendering

  private renderCells() {
    const { types, entries, notes } = this.store;
    const sig = JSON.stringify(types.map((t) => [t.id, t.name, t.color, t.role]));
    if (sig !== this.cellTypesSig) {
      this.cellSigs = new WeakMap();
      this.cellTypesSig = sig;
    }
    const roles = roleMap(types);
    const byId = new Map(types.map((t) => [t.id, t]));
    const order = new Map(types.map((t, i) => [t.id, i]));
    for (const [date, cell] of this.cells) {
      const ids = (entries.get(date) ?? []).filter((id) => order.has(id)).sort((a, b) => order.get(a)! - order.get(b)!);
      const note = notes.get(date);
      const key = ids.join(",") + (note ? "|" + note.icon + "|" + note.comment : "");
      if (this.cellSigs.get(cell) === key) continue;
      this.cellSigs.set(cell, key);
      const fills = cell.firstChild as HTMLElement;
      fills.textContent = "";
      for (const id of ids) {
        const type = byId.get(id)!;
        const s = document.createElement("span");
        s.style.backgroundColor = type.color;
        if (type.role === "needs_cover") s.className = "needs";
        fills.append(s);
      }
      cell.classList.toggle("has-fill", ids.length > 0);
      cell.style.color = ids.length ? contrastText(byId.get(ids[0])!.color) : "";
      cell.classList.toggle("gap", isGap(date, ids, roles));
      cell.querySelector(".note-icon")!.textContent = note?.icon ?? "";
      cell.classList.toggle("has-comment", !!note?.comment);
      const names = ids.map((id) => byId.get(id)!.name).join(", ");
      cell.title =
        fmtDate(this.store.i18n.locale, date, LONG_DATE) +
        (names ? "\n" + names : "") +
        (note ? "\n" + noteText(note) : "");
    }
  }

  private renderSelection() {
    // Only touch cells whose state changed since the last call.
    const { selection: sel, focus: storeFocus, readOnly } = this.store;
    for (const d of this.shownSel) {
      if (!sel.has(d)) this.cellFor(d)?.classList.remove("sel");
    }
    for (const d of sel) {
      if (!this.shownSel.has(d)) this.cellFor(d)?.classList.add("sel");
    }
    const focus = storeFocus && sel.has(storeFocus) ? storeFocus : null;
    if (focus !== this.shownFocus) {
      this.cellFor(this.shownFocus)?.classList.remove("focus");
      this.cellFor(focus)?.classList.add("focus");
    }
    this.shownSel = new Set(sel);
    this.shownFocus = focus;
    const days = this.store.selectedDays();
    const contiguous = days.length > 0 && range(days[0], days[days.length - 1]).length === days.length;
    const last = !readOnly && contiguous && this.cellFor(days[days.length - 1]);
    if (last) last.append(this.fillHandle);
    else this.fillHandle.remove();
  }

  // ------------------------------------------------------------- zoom + scrolling

  applyZoom({ keepView = true } = {}) {
    const { zoom, alwaysWeekdays } = viewPrefs();
    const keep = keepView && !monthView() ? (this.store.focus ?? this.centerDate()) : null;
    this.wrap.style.setProperty("--days", String(zoom));
    this.wrap.classList.toggle("show-wd", zoom <= SHOW_WEEKDAYS || alwaysWeekdays);
    if (keep) this.centerOn(keep);
  }

  /** Wide screens: measures where the calendar starts and what sits below it, so it can end
   *  at the bottom of the screen and keep the day numbers and month names in view. */
  private fitWindow() {
    const r = this.wrap.getBoundingClientRect();
    const below = this.planner.getBoundingClientRect().bottom - r.bottom;
    this.wrap.style.setProperty("--wrap-top", `${Math.round(r.top + scrollY)}px`);
    this.wrap.style.setProperty("--wrap-below", `${Math.max(0, Math.round(below))}px`);
  }

  /** The day in the middle of the visible part of the calendar. */
  private centerDate() {
    const corner = this.grid.firstElementChild as HTMLElement | null;
    if (!corner) return null;
    const r = this.wrap.getBoundingClientRect();
    const top = Math.max(r.top + corner.offsetHeight, 0);
    const bottom = Math.min(r.bottom, innerHeight);
    const left = r.left + corner.offsetWidth;
    return this.dateAt((left + r.right) / 2, (top + bottom) / 2);
  }

  /** Scrolls only the calendar (not the page) so the day sits in the middle of the visible
   *  cells, clear of the sticky day numbers and month names. */
  centerOn(date: string) {
    const cell = this.cellFor(date);
    if (!cell) return;
    if (monthView()) return cell.scrollIntoView({ block: "center" }); // the page scrolls
    const corner = this.grid.firstElementChild as HTMLElement;
    const left = corner.offsetWidth,
      top = corner.offsetHeight;
    this.wrap.scrollTo({
      left: cell.offsetLeft - left - (this.wrap.clientWidth - left - cell.offsetWidth) / 2,
      top: cell.offsetTop - top - (this.wrap.clientHeight - top - cell.offsetHeight) / 2,
    });
  }

  scrollTo(date: string) {
    this.cellFor(date)?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  // ------------------------------------------------------------- pointer input

  dateAt(x: number, y: number): string | null {
    const el = document.elementFromPoint(x, y)?.closest?.(".cell[data-date]") as HTMLElement | null;
    return el?.dataset.date ?? null;
  }

  private fillTargets(src: string[], hover: string) {
    const start = src[0];
    const end = src[src.length - 1];
    if (hover > end) {
      return { days: range(addDays(end, 1), hover), backwards: false };
    }
    if (hover < start) {
      return { days: range(hover, addDays(start, -1)), backwards: true };
    }
    return { days: [] as string[], backwards: false };
  }

  private showFillPreview(days: string[]) {
    const next = new Set(days);
    for (const d of this.previewed) {
      if (!next.has(d)) this.cellFor(d)?.classList.remove("fill-preview");
    }
    for (const d of next) {
      if (!this.previewed.has(d)) {
        this.cellFor(d)?.classList.add("fill-preview");
      }
    }
    this.previewed = next;
    if (this.drag?.mode === "fill") this.cb.onFill(days.length);
  }

  /** Aborts a fill drag in progress; returns whether there was one. */
  cancelFill() {
    if (this.drag?.mode !== "fill") return false;
    if (this.grid.hasPointerCapture(this.drag.pointerId)) {
      this.grid.releasePointerCapture(this.drag.pointerId);
    }
    this.setDrag(null);
    this.showFillPreview([]);
    this.cb.onFill(null);
    return true;
  }

  private setDrag(drag: Drag | null) {
    this.drag = drag;
    this.store.dragging = !!drag;
  }

  private bindPointer() {
    const g = this.grid;
    const on = <K extends keyof HTMLElementEventMap>(
      type: K,
      fn: (e: HTMLElementEventMap[K]) => void,
      opts?: AddEventListenerOptions,
    ) => {
      g.addEventListener(type, fn, opts);
      this.cleanup.push(() => g.removeEventListener(type, fn, opts));
    };
    on("pointerdown", (e) => this.onPointerDown(e));
    on("pointermove", (e) => this.onPointerMove(e));
    on("pointerup", (e) => this.onPointerUp(e));
    on("pointercancel", () => {
      if (!this.cancelFill()) this.endDrag();
    });
    // A range selection by touch must not scroll the page or the calendar.
    on(
      "touchmove",
      (e) => {
        if (this.drag && this.drag.mode !== "tap") e.preventDefault();
      },
      { passive: false },
    );
    on("contextmenu", (e) => {
      if (this.lastPointer === "touch") e.preventDefault();
    });
    on("dblclick", (e) => {
      // The target is the grid itself after a pointer capture, so look the day up by position.
      const date = this.dateAt(e.clientX, e.clientY);
      if (!date || this.store.readOnly) return;
      this.store.select(date);
      this.cb.onNote();
    });
  }

  private onPointerDown(e: PointerEvent) {
    const store = this.store;
    this.lastPointer = e.pointerType;
    if (e.button !== 0) return;
    const target = e.target as HTMLElement;
    const handle = target.closest(".fill-handle");
    const date = (target.closest(".cell[data-date]") as HTMLElement | null)?.dataset.date;
    if (!date) return;
    this.grid.focus({ preventScroll: true });

    if (handle && !store.readOnly) {
      e.preventDefault();
      this.setDrag({
        mode: "fill",
        src: store.selectedDays(),
        targets: [],
        pointerId: e.pointerId,
      });
      this.grid.setPointerCapture(e.pointerId);
      this.showFillPreview([]);
      return;
    }

    if (e.pointerType === "touch") {
      // Touch: a tap selects a day (see onPointerUp) and a long press starts selecting a
      // range, so a swipe still scrolls; the touchmove listener stops the scrolling once a
      // range selection runs. In multi-select mode both add to the selection.
      const timer = window.setTimeout(() => {
        if (this.drag?.mode !== "tap" || this.drag.date !== date) return;
        const base = new Set(store.multi ? store.selection : []);
        this.setDrag({
          mode: "select",
          anchor: date,
          base,
          last: date,
          touch: true,
        });
        store.setSelection(base);
        store.select(date, date, { add: true });
        navigator.vibrate?.(10);
      }, LONG_PRESS_MS);
      this.setDrag({ mode: "tap", date, x: e.clientX, y: e.clientY, timer });
      return;
    }

    e.preventDefault();
    if (e.shiftKey && store.anchor) {
      store.select(store.anchor, date);
      this.setDrag({
        mode: "select",
        anchor: store.anchor,
        base: new Set(),
        last: date,
      });
    } else if (e.ctrlKey || e.metaKey) {
      const base = new Set(store.selection);
      if (base.has(date)) {
        store.toggleDay(date);
        this.setDrag(null);
        return;
      }
      this.setDrag({ mode: "select", anchor: date, base, last: date });
      store.setSelection(base);
      store.select(date, date, { add: true });
    } else {
      this.setDrag({
        mode: "select",
        anchor: date,
        base: new Set(),
        last: date,
      });
      store.select(date);
    }
    this.grid.setPointerCapture(e.pointerId);
  }

  private onPointerMove(e: PointerEvent) {
    const drag = this.drag;
    if (!drag) return;
    if (drag.mode === "tap") {
      if (Math.hypot(e.clientX - drag.x, e.clientY - drag.y) > 10) {
        this.endDrag(); // a scroll
      }
      return;
    }
    if (drag.mode === "select" && drag.touch) {
      drag.x = e.clientX;
      drag.y = e.clientY;
      this.edgeScroll();
    }
    this.extendDrag(this.dateAt(e.clientX, e.clientY));
  }

  private extendDrag(date: string | null) {
    const drag = this.drag;
    if (!date || !drag || drag.mode === "tap" || date === drag.last) return;
    drag.last = date;
    if (drag.mode === "select") {
      this.store.setSelection(drag.base);
      this.store.select(drag.anchor, date, { add: true });
    } else {
      const { days, backwards } = this.fillTargets(drag.src, date);
      drag.targets = this.store.targetDays(days);
      drag.backwards = backwards;
      this.showFillPreview(drag.targets);
    }
  }

  private endDrag() {
    if (this.drag?.mode === "tap") clearTimeout(this.drag.timer);
    this.setDrag(null);
  }

  /** Touch range selection in the month view: scrolls the page while the finger is near the
   *  top of the screen or the bottom dock, so a range can span several months. */
  private edgeScroll() {
    if (this.edgeScrolling || !monthView()) return;
    this.edgeScrolling = true;
    const step = () => {
      const d = this.drag;
      const bottom = this.cb.dockTop();
      const touch = d?.mode === "select" && d.touch ? d : null;
      const dir = !touch ? 0 : touch.y! < 64 ? -1 : touch.y! > bottom - 32 ? 1 : 0;
      if (!dir) {
        this.edgeScrolling = false;
        return;
      }
      scrollBy(0, dir * 6);
      this.extendDrag(this.dateAt(touch!.x!, touch!.y!));
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  private onPointerUp(e: PointerEvent) {
    const d = this.drag;
    if (!d) return;
    const store = this.store;
    this.endDrag();
    if (d.mode === "tap") {
      if (Math.hypot(e.clientX - d.x, e.clientY - d.y) > 10) return; // it was a scroll
      if (store.rangeMode && store.anchor) {
        store.select(store.anchor, d.date, { add: store.multi });
        store.setRangeMode(false);
      } else if (store.multi) {
        store.toggleDay(d.date);
      } else {
        store.select(d.date);
      }
      return;
    }
    if (d.mode === "fill") {
      this.showFillPreview([]);
      this.cb.onFill(null);
      if (!d.targets.length) return;
      let pattern = patternOf(store.entries, store.targetDays(d.src));
      if (d.backwards) {
        // Align the repeating pattern so that it ends right before the source.
        const n = pattern.length;
        const shift = (n - (d.targets.length % n)) % n;
        pattern = pattern.slice(shift).concat(pattern.slice(0, shift));
      }
      store.commit(fillWith(d.targets, pattern));
      const all = [...d.src, ...d.targets].sort();
      store.select(d.backwards ? all[all.length - 1] : all[0], d.backwards ? all[0] : all[all.length - 1]);
    }
  }
}
