// Which events reach the family's notification channels (phase 7): per family and event, on or
// off and to which channels (null: all enabled ones), plus a small memory per event so the
// worker never sends the same thing twice. A missing row means the defaults below.

import { and, eq } from "drizzle-orm";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { notificationPrefs } from "@/lib/db/schema";
import { type Actor, requireRole } from "@/lib/families/roles";
import { getChannelRow } from "./channels";
import { type NotifyResult, type Message, type Sender, notifyFamily } from "./index";

export { DEFAULT_ENABLED, EVENT_HAS_CHANNELS, type EventPref, NOTIFY_EVENTS, type NotifyEvent } from "./prefs-shared";
import { DEFAULT_ENABLED, type EventPref, NOTIFY_EVENTS, type NotifyEvent } from "./prefs-shared";

type Row = typeof notificationPrefs.$inferSelect;

function parse<T>(text: string | null, fallback: T): T {
  if (text === null) return fallback;
  try {
    return JSON.parse(text) as T;
  } catch {
    return fallback;
  }
}

function row(db: Db, familyId: string, event: NotifyEvent): Row | undefined {
  return db
    .select()
    .from(notificationPrefs)
    .where(and(eq(notificationPrefs.familyId, familyId), eq(notificationPrefs.event, event)))
    .get();
}

export function getPref(db: Db, familyId: string, event: NotifyEvent): EventPref {
  const r = row(db, familyId, event);
  return {
    event,
    enabled: r ? r.enabled : DEFAULT_ENABLED[event],
    channelIds: r ? parse<string[] | null>(r.channelIds, null) : null,
  };
}

export function getPrefs(db: Db, familyId: string): EventPref[] {
  return NOTIFY_EVENTS.map((e) => getPref(db, familyId, e));
}

export const prefInputSchema = z.object({
  event: z.enum(NOTIFY_EVENTS),
  enabled: z.boolean(),
  channelIds: z.array(z.string()).max(50).nullable(),
});

/** Turns an event on or off and picks its channels (editors only; the channels must be the
 *  family's). */
export function setPref(db: Db, actor: Actor, familyId: string, raw: unknown, now: Date): EventPref {
  requireRole(db, actor, familyId, "editor");
  const input = prefInputSchema.parse(raw);
  const ids = input.channelIds && [...new Set(input.channelIds)];
  for (const id of ids ?? []) getChannelRow(db, familyId, id);
  const values = { enabled: input.enabled, channelIds: ids ? JSON.stringify(ids) : null, updatedAt: now };
  db.insert(notificationPrefs)
    .values({ familyId, event: input.event, ...values })
    .onConflictDoUpdate({ target: [notificationPrefs.familyId, notificationPrefs.event], set: values })
    .run();
  return getPref(db, familyId, input.event);
}

/** The event's memory (what the worker sent last). */
export function readState<T extends object>(db: Db, familyId: string, event: NotifyEvent): Partial<T> {
  return parse<Partial<T>>(row(db, familyId, event)?.state ?? null, {});
}

export function writeState(db: Db, familyId: string, event: NotifyEvent, state: object, now: Date): void {
  const json = JSON.stringify(state);
  db.insert(notificationPrefs)
    .values({ familyId, event, enabled: DEFAULT_ENABLED[event], state: json, updatedAt: now })
    .onConflictDoUpdate({
      target: [notificationPrefs.familyId, notificationPrefs.event],
      set: { state: json },
    })
    .run();
}

/** Sends `message` for `event` to its channels; null when the family turned the event off. */
export async function notifyEvent(
  db: Db,
  familyId: string,
  event: NotifyEvent,
  message: Message,
  opts: { send?: Sender } = {},
): Promise<NotifyResult | null> {
  const pref = getPref(db, familyId, event);
  if (!pref.enabled) return null;
  return notifyFamily(db, familyId, message, { channelIds: pref.channelIds ?? undefined, send: opts.send });
}
