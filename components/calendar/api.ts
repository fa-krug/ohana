// Client of the family API (/api/v1/families/{id}/...) for the calendar pages: family-planner's
// app/src/lib/api.ts (calendar calls), signed in by the session cookie.

import type { EntryOp, EntryType, NoteOp, Role } from "@/lib/calendar/core";

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
}

export class ApiError extends Error {
  constructor(
    message: string,
    /** 0: no answer (offline). */
    public status: number,
  ) {
    super(message);
  }
}

const enc = encodeURIComponent;
const fam = (id: string) => `/api/v1/families/${enc(id)}`;

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  let res: Response;
  try {
    res = await fetch(path, {
      method,
      credentials: "same-origin",
      cache: "no-store",
      headers: body === undefined ? {} : { "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (err) {
    throw new ApiError((err as Error).message || "Network error", 0);
  }
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new ApiError(data?.error ?? res.statusText, res.status);
  return data as T;
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
};

/** The public feed URL of a family (its feed id, never the family id). */
export function calendarUrl(appUrl: string, feedId: string, params: Record<string, string> = {}): string {
  const qs = new URLSearchParams(params).toString();
  return `${appUrl.replace(/\/+$/, "")}/api/v1/families/${enc(feedId)}/calendar.ics${qs ? "?" + qs : ""}`;
}
