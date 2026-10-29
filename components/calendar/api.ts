// Client of the family API (/api/v1/families/{id}/...) for the calendar pages: family-planner's
// app/src/lib/api.ts (calendar calls), signed in by the session cookie.

import { ApiError, enc, fam, request } from "@/lib/api/client";
import type { EntryOp, EntryType, NoteOp, Role } from "@/lib/calendar/core";

export { ApiError };

export type Access = "edit" | "view";

export interface Family {
  id: string;
  feedId: string;
  legacyId?: string;
  name: string;
  access: Access;
  readOnly: boolean;
  updatedAt: string;
}

export interface FamilyState {
  family: Family;
  types: EntryType[];
  typeYears?: number[];
  entries: Record<string, string[]>;
  notes?: Record<string, { icon: string; comment: string }>;
  /** Timed events by day, e.g. booked appointments (phase 7). */
  events?: Record<string, CalEvent[]>;
}

export interface CalEvent {
  id: string;
  date: string;
  start: string | null;
  end: string | null;
  title: string;
  location: string;
  person: string;
  note: string;
  url: string;
  source: "manual" | "appointment";
  searchId: string | null;
}

export const api = {
  getFamily: (id: string, year: number) => request<FamilyState>("GET", `${fam(id)}?year=${year}`),
  rotateLink: (id: string, link: "feed" | "legacy", year: number) =>
    request<FamilyState>("POST", `${fam(id)}/links?year=${year}`, { link }),
  addType: (id: string, year: number, type: { name: string; color: string; role: Role }) =>
    request<EntryType>("POST", `${fam(id)}/types?year=${year}`, type),
  updateType: (id: string, year: number, typeId: string, patch: Partial<EntryType>) =>
    request<EntryType>("PATCH", `${fam(id)}/types/${enc(typeId)}?year=${year}`, patch),
  deleteType: (id: string, year: number, typeId: string) =>
    request<unknown>("DELETE", `${fam(id)}/types/${enc(typeId)}?year=${year}`),
  copyTypes: (id: string, from: number, to: number) =>
    request<EntryType[]>("POST", `${fam(id)}/types/copy`, { from, to }),
  applyOps: (id: string, ops: EntryOp[]) => request<unknown>("POST", `${fam(id)}/entries`, { ops }),
  applyNoteOps: (id: string, ops: NoteOp[]) => request<unknown>("POST", `${fam(id)}/notes`, { ops }),
  /** The whole family (all years, finances) as an export file. */
  exportFamily: (id: string) => request<Record<string, unknown>>("GET", `${fam(id)}/export`),
  /** Replaces the calendar and the finances with an export file's; answers like getFamily. */
  importFamily: (id: string, year: number, file: unknown) =>
    request<FamilyState>("POST", `${fam(id)}/import?year=${year}`, file),
};

/** The public feed URL of a family (its feed id, never the family id). */
export function calendarUrl(appUrl: string, feedId: string, params: Record<string, string> = {}): string {
  const qs = new URLSearchParams(params).toString();
  return `${appUrl.replace(/\/+$/, "")}/api/v1/families/${enc(feedId)}/calendar.ics${qs ? "?" + qs : ""}`;
}
