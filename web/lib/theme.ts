// Light / dark / like the system, per device (localStorage). The `.dark` class on <html>
// switches the colors (globals.css); `themeScript` applies the stored choice in <head>
// before the first paint and follows the OS while the choice is "system".
// Browser-safe and server-safe: no React here (the hook is in theme-client.ts).

export type Theme = "system" | "light" | "dark";

export const THEMES: readonly Theme[] = ["system", "light", "dark"];
export const THEME_KEY = "ohana-theme";
/** Sent on `window` by `setTheme` (theme-client.ts) so the script re-applies the theme. */
export const THEME_EVENT = "ohana-theme";
export const DARK_QUERY = "(prefers-color-scheme: dark)";

/** A stored value as a theme; anything unknown (or nothing) is "system". */
export function parseTheme(value: string | null | undefined): Theme {
  return value === "light" || value === "dark" ? value : "system";
}

/** Whether the page is dark for this choice and the OS preference. */
export function resolveDark(theme: Theme, systemDark: boolean): boolean {
  return theme === "dark" || (theme === "system" && systemDark);
}

/**
 * The blocking inline script of the root layout's <head>. It must stay self-contained
 * (it runs before any bundle), so it repeats `parseTheme` / `resolveDark`; the
 * `THEME_EVENT` (from `setTheme`) and other tabs' storage changes re-apply it.
 */
export const themeScript = `(function(){
var d=document.documentElement,k=${JSON.stringify(THEME_KEY)},m;
try{m=window.matchMedia(${JSON.stringify(DARK_QUERY)})}catch(e){}
function read(){try{var v=localStorage.getItem(k);return v==="light"||v==="dark"?v:"system"}catch(e){return "system"}}
function apply(){var t=read(),dark=t==="dark"||(t==="system"&&!!m&&m.matches);
d.classList.toggle("dark",dark);d.style.colorScheme=dark?"dark":"light"}
apply();
if(m){if(m.addEventListener)m.addEventListener("change",apply);else if(m.addListener)m.addListener(apply)}
window.addEventListener(${JSON.stringify(THEME_EVENT)},apply);
window.addEventListener("storage",function(e){if(e.key===k||e.key===null)apply()});
})();`;
