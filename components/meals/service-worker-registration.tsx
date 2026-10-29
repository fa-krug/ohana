"use client";

import { useEffect } from "react";

/** Registers `/sw.js` (cookless's runtime cache: static assets and recipe images cache-first,
 *  the meals pages network-first) so the shopping list opens without a connection. Only in
 *  production builds: in dev it would cache-first Next's hot-reloaded chunks. */
export function ServiceWorkerRegistration() {
  useEffect(() => {
    if (process.env.NODE_ENV !== "production" || !("serviceWorker" in navigator)) return;

    function register() {
      navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" }).catch(() => {
        // Registration failures are non-fatal; the app works online without the SW.
      });
    }

    if (document.readyState === "complete") {
      register();
      return;
    }
    window.addEventListener("load", register);
    return () => window.removeEventListener("load", register);
  }, []);

  return null;
}
