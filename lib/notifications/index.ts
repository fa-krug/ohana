// Family-wide notifications, usable by every module: `notifyFamily` sends one message to
// the family's enabled channels (or a chosen subset). A failing channel is logged and
// skipped; it never fails the caller. Call it from the worker, not from a request.

import type { Db } from "@/lib/db";
import { type Actor, requireRole } from "@/lib/families/roles";
import { AuthError } from "@/lib/auth/errors";
import { getAppUrl } from "@/lib/auth/config";
import { getChannelRow, openChannel, openChannels } from "./channels";
import { familyLocale, translator } from "./locale";
import { type Channel, type Message, deliver } from "./send";

export type { Message, Channel } from "./send";

export type Sender = (channel: Channel, msg: Message) => Promise<void>;

export interface NotifyResult {
  sent: number;
  failed: number;
}

/**
 * Sends `message` to the family's enabled channels. `channelIds`: only these (an empty list
 * sends nothing); omitted: all of them. `send` replaces the network delivery (tests).
 */
export async function notifyFamily(
  db: Db,
  familyId: string,
  message: Message,
  opts: { channelIds?: string[]; send?: Sender } = {},
): Promise<NotifyResult> {
  const send = opts.send ?? deliver;
  const result: NotifyResult = { sent: 0, failed: 0 };
  for (const c of openChannels(db, familyId, opts.channelIds)) {
    try {
      if (c.error) throw new Error(c.error);
      await send(c, message);
      result.sent += 1;
    } catch (err) {
      result.failed += 1;
      console.warn(`[notifications] ${c.provider} channel "${c.name}" failed:`, err instanceof Error ? err.message : err);
    }
  }
  return result;
}

/** Sends a test message to one channel (even a disabled one); throws with the reason. */
export async function sendTestNotification(
  db: Db,
  actor: Actor,
  familyId: string,
  channelId: string,
  opts: { send?: Sender } = {},
): Promise<void> {
  requireRole(db, actor, familyId, "editor");
  const row = getChannelRow(db, familyId, channelId);
  const channel = openChannel(row); // also a disabled one
  if (channel.error) throw new AuthError(400, channel.error);
  const t = translator(familyLocale(db, familyId));
  const msg: Message = {
    title: t("notifications.test.title"),
    body: t("notifications.test.body", { channel: row.name }),
    url: `${getAppUrl()}/f/${familyId}/settings?tab=household`,
  };
  try {
    await (opts.send ?? deliver)(channel, msg);
  } catch (err) {
    throw new AuthError(502, err instanceof Error ? err.message : String(err));
  }
}
