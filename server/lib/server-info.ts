// What the server tells clients about itself (GET /api/v1/server, public): its version, the
// API version the native app checks, and which modules are on. A self-hoster turns modules off
// with DISABLED_MODULES (comma list, e.g. "appointments,assistant"); the calendar is always on.
// A turned-off module's routes answer 404, the worker skips its jobs and the assistant loses its
// tools; its data stays in the database.

import pkg from "../package.json";
import { pushRelayUrl } from "./push/config";

/** Raised when a change to the API would break an older app: the app refuses older servers. */
export const API_VERSION = 1;

export const MODULES = ["calendar", "finance", "meals", "appointments", "chores", "assistant"] as const;
export type ModuleName = (typeof MODULES)[number];

/** Modules that can be turned off (the calendar can't: the overview and the events use it). */
export const OPTIONAL_MODULES: readonly ModuleName[] = ["finance", "meals", "appointments", "chores", "assistant"];

/** The modules that are on, from DISABLED_MODULES (unknown names are ignored). */
export function enabledModules(env: Record<string, string | undefined> = process.env): ModuleName[] {
  const off = new Set(
    (env.DISABLED_MODULES ?? "")
      .split(",")
      .map((m) => m.trim().toLowerCase())
      .filter(Boolean),
  );
  return MODULES.filter((m) => !(OPTIONAL_MODULES.includes(m) && off.has(m)));
}

export function moduleEnabled(m: ModuleName, env: Record<string, string | undefined> = process.env): boolean {
  return enabledModules(env).includes(m);
}

/** The release (OHANA_VERSION, set when the image is built from a tag), else package.json's. */
export function serverVersion(env: Record<string, string | undefined> = process.env): string {
  return env.OHANA_VERSION?.trim() || pkg.version;
}

export interface ServerInfo {
  name: "Ohana";
  version: string;
  apiVersion: number;
  modules: ModuleName[];
  /** Push to the app (phase 9): the relay the app registers with; null when it's off. */
  push: { relay: string } | null;
}

export function serverInfo(env: Record<string, string | undefined> = process.env): ServerInfo {
  const relay = pushRelayUrl(env);
  return {
    name: "Ohana",
    version: serverVersion(env),
    apiVersion: API_VERSION,
    modules: enabledModules(env),
    push: relay ? { relay } : null,
  };
}

/** The module a family API path belongs to (its first part), if it can be turned off. */
export function moduleOfFamilyPath(rest: string[]): ModuleName | null {
  switch (rest[0]) {
    case "finance":
      return "finance";
    case "meals":
    case "recipes":
    case "shopping":
      return "meals";
    case "appointments":
      return "appointments";
    case "chores":
      return "chores";
    case "ai":
    case "agent":
      return "assistant";
    default:
      return null;
  }
}
