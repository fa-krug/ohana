import { Banknote, CalendarDays, LayoutGrid, Stethoscope, UtensilsCrossed, type LucideIcon } from "lucide-react";

/** The family's modules, in sidebar order. `ready`: built already (else "coming soon"). */
export const MODULES: { key: string; icon: LucideIcon; ready: boolean }[] = [
  { key: "calendar", icon: CalendarDays, ready: true },
  { key: "finance", icon: Banknote, ready: false },
  { key: "meals", icon: UtensilsCrossed, ready: true },
  { key: "appointments", icon: Stethoscope, ready: true },
];

export const OVERVIEW_ICON = LayoutGrid;

export function isModule(key: string): boolean {
  return MODULES.some((m) => m.key === key);
}
