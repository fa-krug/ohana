import { runInNewContext } from "node:vm";
import { describe, expect, it } from "vitest";
import { parseTheme, resolveDark, THEME_EVENT, THEME_KEY, themeScript } from "@/lib/theme";

/** Runs the <head> script against a fake document, storage and OS preference. */
function page(stored: string | null, systemDark: boolean, storageThrows = false) {
  const classes = new Set<string>();
  const html = {
    classList: { toggle: (c: string, on: boolean) => (on ? classes.add(c) : classes.delete(c)) },
    style: { colorScheme: "" },
  };
  const store = new Map<string, string>(stored === null ? [] : [[THEME_KEY, stored]]);
  const listeners = new Map<string, ((e?: unknown) => void)[]>();
  const mqListeners: (() => void)[] = [];
  const mq = { matches: systemDark, addEventListener: (_: string, f: () => void) => mqListeners.push(f) };
  const window = {
    matchMedia: () => mq,
    addEventListener: (type: string, f: (e?: unknown) => void) =>
      listeners.set(type, [...(listeners.get(type) ?? []), f]),
  };
  const localStorage = {
    getItem: (k: string) => {
      if (storageThrows) throw new Error("blocked");
      return store.get(k) ?? null;
    },
  };
  runInNewContext(themeScript, { window, document: { documentElement: html }, localStorage });
  return {
    dark: () => classes.has("dark"),
    scheme: () => html.style.colorScheme,
    setStored: (v: string) => store.set(THEME_KEY, v),
    setSystem: (dark: boolean) => {
      mq.matches = dark;
      mqListeners.forEach((f) => f());
    },
    fire: (type: string, e?: unknown) => listeners.get(type)?.forEach((f) => f(e)),
  };
}

describe("theme", () => {
  it("reads unknown or missing values as system", () => {
    expect(parseTheme(null)).toBe("system");
    expect(parseTheme("purple")).toBe("system");
    expect(parseTheme("light")).toBe("light");
    expect(parseTheme("dark")).toBe("dark");
  });

  it("resolves the choice against the OS", () => {
    expect(resolveDark("system", true)).toBe(true);
    expect(resolveDark("system", false)).toBe(false);
    expect(resolveDark("light", true)).toBe(false);
    expect(resolveDark("dark", false)).toBe(true);
  });

  it("the head script applies the stored choice and follows the OS on system", () => {
    const forcedLight = page("light", true);
    expect([forcedLight.dark(), forcedLight.scheme()]).toEqual([false, "light"]);

    const p = page(null, false);
    expect([p.dark(), p.scheme()]).toEqual([false, "light"]);
    p.setSystem(true);
    expect([p.dark(), p.scheme()]).toEqual([true, "dark"]);

    p.setStored("light");
    p.fire(THEME_EVENT);
    expect(p.dark()).toBe(false);
    p.setSystem(true); // no longer follows the OS
    expect(p.dark()).toBe(false);

    p.setStored("dark");
    p.fire("storage", { key: THEME_KEY }); // another tab
    expect(p.dark()).toBe(true);
  });

  it("falls back to the OS when storage is blocked", () => {
    expect(page(null, true, true).dark()).toBe(true);
  });
});
