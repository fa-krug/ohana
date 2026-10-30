"use client";

// The theme choice of this device for React; applying it is the job of `themeScript`
// (lib/theme.ts), which listens for the event `setTheme` sends.

import { useSyncExternalStore } from "react";
import { parseTheme, THEME_EVENT as EVENT, THEME_KEY, type Theme } from "@/lib/theme";

function read(): Theme {
  try {
    return parseTheme(localStorage.getItem(THEME_KEY));
  } catch {
    return "system";
  }
}

function subscribe(onChange: () => void) {
  const onStorage = (e: StorageEvent) => {
    if (e.key === THEME_KEY || e.key === null) onChange();
  };
  window.addEventListener(EVENT, onChange);
  window.addEventListener("storage", onStorage);
  return () => {
    window.removeEventListener(EVENT, onChange);
    window.removeEventListener("storage", onStorage);
  };
}

export function setTheme(theme: Theme) {
  try {
    if (theme === "system") localStorage.removeItem(THEME_KEY);
    else localStorage.setItem(THEME_KEY, theme);
  } catch {
    // storage blocked (private mode): nothing to keep
  }
  window.dispatchEvent(new Event(EVENT));
}

export function useTheme(): Theme {
  return useSyncExternalStore(subscribe, read, () => "system");
}
