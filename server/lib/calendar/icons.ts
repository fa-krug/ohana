// Icons of the calendar: SF Symbol names the app draws (entry types and day notes).

import { HttpError } from "@/lib/api/http";
import type { Role } from "./store";

/** A type's icon when it has none of its own. */
export const ROLE_ICONS: Record<Role, string> = {
  none: "tag",
  needs_cover: "exclamationmark.triangle",
  covers: "checkmark.shield",
  day_off: "sun.max",
};

const MAX_SYMBOL = 64;
const SYMBOL_RE = /^[a-z0-9]+(\.[a-z0-9]+)*$/;

/** Whether `v` looks like an SF Symbol name ("sun.max", "birthday.cake"). */
export function isSymbolName(v: unknown): v is string {
  return typeof v === "string" && v.length <= MAX_SYMBOL && SYMBOL_RE.test(v);
}

/** An icon given as an SF Symbol name; 400 otherwise. */
export function cleanSymbol(v: unknown): string {
  if (!isSymbolName(v)) throw new HttpError(400, "icon must be an SF Symbol name");
  return v;
}

/** A type's stored icon: null (the role's) or an SF Symbol name. */
export function cleanTypeIcon(v: unknown): string | null {
  return v === undefined || v === null ? null : cleanSymbol(v);
}

/** The icon a type shows: its own, else its role's. */
export function typeIcon(t: { icon: string | null; role: Role }): string {
  return t.icon ?? ROLE_ICONS[t.role] ?? ROLE_ICONS.none;
}
