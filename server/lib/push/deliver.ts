// Sends a notification to the app devices of a family's members (phase 9): every member's
// registered devices that didn't mute the family, or only those of some accounts (the
// assistant's chat is one person's). Sealed per device, sent through the relay in one go.
// A device the relay says is gone (or whose token it doesn't know) is forgotten: the app
// registers again at its next start. Never throws; call it from the worker.

import { eq, inArray } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { familyMembers, pushDevices } from "@/lib/db/schema";
import { pushRelayUrl } from "./config";
import { type PushDeviceRow, mutedOf, openDevice } from "./devices";
import { type PushPayload, collapseIdFor, pathOfUrl, sealPayload } from "./payload";
import { type RelayClient, type RelayMessage, type RelayResult, fetchRelay } from "./relay";

export interface PushMessage {
  title: string;
  body: string;
  /** Where a tap leads (an absolute URL of this server or a path). */
  url?: string;
  /** What should replace an earlier notification (e.g. the chat, the search). */
  collapseKey?: string;
  event?: string;
}

export interface PushResult {
  sent: number;
  failed: number;
}

export interface PushOptions {
  /** Only these accounts' devices. */
  userIds?: string[];
  relay?: RelayClient;
  /** The relay URL (tests); else PUSH_RELAY_URL. */
  relayUrl?: string | null;
  now?: Date;
}

/** The registered devices of a family's members, minus those that muted it. */
export function familyDevices(db: Db, familyId: string, userIds?: string[]): PushDeviceRow[] {
  const members = db
    .select({ userId: familyMembers.userId })
    .from(familyMembers)
    .where(eq(familyMembers.familyId, familyId))
    .all()
    .map((m) => m.userId)
    .filter((id) => !userIds || userIds.includes(id));
  if (members.length === 0) return [];
  return db
    .select()
    .from(pushDevices)
    .where(inArray(pushDevices.userId, members))
    .all()
    .filter((d) => !mutedOf(d).includes(familyId));
}

/** Seals `message` for each device and sends it; updates or forgets the devices by the answers. */
export async function pushToDevices(
  db: Db,
  devices: PushDeviceRow[],
  message: PushMessage,
  familyId: string | undefined,
  opts: Omit<PushOptions, "userIds"> = {},
): Promise<PushResult> {
  const result: PushResult = { sent: 0, failed: 0 };
  const relayUrl = opts.relayUrl === undefined ? pushRelayUrl() : opts.relayUrl;
  if (!relayUrl || devices.length === 0) return result;
  const now = opts.now ?? new Date();
  const payload: PushPayload = {
    v: 1,
    title: message.title,
    body: message.body,
    ...(pathOfUrl(message.url ?? "") ? { path: pathOfUrl(message.url ?? "") } : {}),
    ...(familyId ? { familyId } : {}),
    ...(message.event ? { event: message.event } : {}),
  };

  const sendable: { device: PushDeviceRow; msg: RelayMessage }[] = [];
  for (const device of devices) {
    const opened = openDevice(device);
    if (!opened) {
      // Sealed with a key this server no longer has: useless, the app registers again.
      db.delete(pushDevices).where(eq(pushDevices.id, device.id)).run();
      result.failed += 1;
      continue;
    }
    sendable.push({
      device,
      msg: {
        relayToken: opened.relayToken,
        payload: sealPayload(opened.key, payload),
        ...(message.collapseKey ? { collapseId: collapseIdFor(opened.key, message.collapseKey) } : {}),
      },
    });
  }
  if (sendable.length === 0) return result;

  let answers: RelayResult[];
  try {
    answers = await (opts.relay ?? fetchRelay).send(
      relayUrl,
      sendable.map((s) => s.msg),
    );
  } catch (e) {
    console.warn("[push] relay failed:", e instanceof Error ? e.message : e);
    answers = sendable.map(() => ({ status: "error" }));
  }

  sendable.forEach(({ device }, i) => {
    const status = answers[i]?.status ?? "error";
    if (status === "ok") {
      result.sent += 1;
      db.update(pushDevices).set({ lastSentAt: now, lastError: null }).where(eq(pushDevices.id, device.id)).run();
    } else if (status === "gone" || status === "invalid") {
      result.failed += 1;
      db.delete(pushDevices).where(eq(pushDevices.id, device.id)).run();
    } else {
      result.failed += 1;
      db.update(pushDevices).set({ lastError: status }).where(eq(pushDevices.id, device.id)).run();
    }
  });
  if (result.failed > 0) console.warn(`[push] ${result.failed} of ${devices.length} pushes failed`);
  return result;
}

/** Pushes `message` to the devices of the family's members (or of `userIds` among them). */
export async function pushToFamily(
  db: Db,
  familyId: string,
  message: PushMessage,
  opts: PushOptions = {},
): Promise<PushResult> {
  const relayUrl = opts.relayUrl === undefined ? pushRelayUrl() : opts.relayUrl;
  if (!relayUrl) return { sent: 0, failed: 0 };
  return pushToDevices(db, familyDevices(db, familyId, opts.userIds), message, familyId, { ...opts, relayUrl });
}
