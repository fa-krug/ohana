// Family-wide notifications, usable by every module: `notifyFamily` sends one message to
// the family's enabled channels (or a chosen subset) and, with `app`, to the members' app
// devices through the push relay (lib/push, phase 9). A failing channel or device is logged
// and skipped; it never fails the caller. Call it from the worker, not from a request.

import type { Db } from "@/lib/db";
import { type Actor, requireRole } from "@/lib/families/roles";
import { AuthError } from "@/lib/auth/errors";
import { getAppUrl } from "@/lib/auth/config";
import { getChannelRow, openChannel, openChannels } from "./channels";
import { familyLocale, translator } from "./locale";
import { pushToFamily } from "@/lib/push/deliver";
import type { RelayClient } from "@/lib/push/relay";
import { type Channel, type Message, deliver } from "./send";

export type { Message, Channel } from "./send";

export type Sender = (channel: Channel, msg: Message) => Promise<void>;

export interface NotifyResult {
  sent: number;
  failed: number;
}

export interface NotifyOptions {
  /** Only these channels (an empty list: none); omitted: all enabled ones. */
  channelIds?: string[];
  /** Replaces the channels' network delivery (tests). */
  send?: Sender;
  /** Also push to the members' app devices (all, or only these accounts'). Default: no. */
  app?: boolean | { userIds: string[] };
  /** The notification event, passed to the app. */
  event?: string;
  /** Replaces the push relay client (tests). */
  push?: RelayClient;
}

/**
 * Sends `message` to the family's enabled channels and, with `app`, its members' app devices.
 * `sent` / `failed` count channels and devices together.
 */
export async function notifyFamily(
  db: Db,
  familyId: string,
  message: Message,
  opts: NotifyOptions = {},
): Promise<NotifyResult> {
  const send = opts.send ?? deliver;
  const result: NotifyResult = { sent: 0, failed: 0 };
  if (opts.app) {
    const pushed = await pushToFamily(
      db,
      familyId,
      { title: message.title, body: message.body, url: message.url, collapseKey: message.collapseKey, event: opts.event },
      { userIds: opts.app === true ? undefined : opts.app.userIds, relay: opts.push },
    );
    result.sent += pushed.sent;
    result.failed += pushed.failed;
  }
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
