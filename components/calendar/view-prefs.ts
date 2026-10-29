// Per-device view settings of the calendar: the zoom (how many days fit across the year grid),
// whether weekday letters show at every zoom, and "skip weekends". Kept in localStorage; a
// blocked storage just means defaults.

import { useSyncExternalStore } from "react";

export const ZOOM = { min: 7, max: 31, initial: 31 };
/** From this zoom on, cells are big enough for weekday letters. */
export const SHOW_WEEKDAYS = 16;
const ZOOM_KEY = "ohana.calendar.daysWide";
const WEEKDAYS_KEY = "ohana.calendar.showWeekdays";
const SKIP_KEY = "ohana.calendar.skipWeekends";

export function readFlag(key: string): boolean {
  try {
    return localStorage.getItem(key) === "1";
  } catch {
    return false;
  }
}

export function writeFlag(key: string, on: boolean): void {
  try {
    localStorage.setItem(key, on ? "1" : "0");
  } catch {
    // storage blocked
  }
}

function readZoom(): number {
  try {
    const n = Number(localStorage.getItem(ZOOM_KEY));
    return n >= ZOOM.min && n <= ZOOM.max ? n : ZOOM.initial;
  } catch {
    return ZOOM.initial;
  }
}

type Prefs = { zoom: number; alwaysWeekdays: boolean; skipWeekends: boolean };

const DEFAULTS: Prefs = { zoom: ZOOM.initial, alwaysWeekdays: false, skipWeekends: false };
let prefs: Prefs | null = null; // read on first use in the browser
const listeners = new Set<() => void>();

export function viewPrefs(): Prefs {
  if (prefs) return prefs;
  if (typeof window === "undefined") return DEFAULTS;
  prefs = { zoom: readZoom(), alwaysWeekdays: readFlag(WEEKDAYS_KEY), skipWeekends: readFlag(SKIP_KEY) };
  return prefs;
}

function update(next: Partial<Prefs>) {
  prefs = { ...viewPrefs(), ...next };
  for (const l of listeners) l();
}

export function subscribeViewPrefs(fn: () => void) {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export function useViewPrefs(): Prefs {
  return useSyncExternalStore(subscribeViewPrefs, viewPrefs, () => DEFAULTS);
}

export function setZoom(n: number) {
  n = Math.min(ZOOM.max, Math.max(ZOOM.min, Math.round(n)));
  try {
    localStorage.setItem(ZOOM_KEY, String(n));
  } catch {
    // storage blocked
  }
  update({ zoom: n });
}

/** Ctrl/⌘ + / − steps by about a quarter; 0 resets. */
export function zoomBy(dir: number) {
  const n = viewPrefs().zoom;
  if (!dir) setZoom(ZOOM.initial);
  else if (dir > 0) setZoom(Math.min(n - 1, Math.round(n / 1.25)));
  else setZoom(Math.max(n + 1, Math.round(n * 1.25)));
}

export function setAlwaysWeekdays(on: boolean) {
  writeFlag(WEEKDAYS_KEY, on);
  update({ alwaysWeekdays: on });
}

export function setSkipWeekends(on: boolean) {
  writeFlag(SKIP_KEY, on);
  update({ skipWeekends: on });
}
