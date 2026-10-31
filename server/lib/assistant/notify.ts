// "Assistant turn finished" (phase 7's notifications everywhere): when a turn that ran for a
// while (ASSISTANT_NOTIFY_AFTER_SECONDS, 30) ends and nobody follows the chat (the app's open
// stream marks it as seen every 15 s; none in the last minute), the family's channels for the
// event get a message with a link to the chat's page. Off by default (Settings → Household).
// Stopped turns are not told (the user stopped them).

import { getAppUrl } from "@/lib/auth/config";
import type { Db } from "@/lib/db";
import { familyLocale, translator } from "@/lib/notifications/locale";
import { notifyEvent } from "@/lib/notifications/prefs";
import type { Sender } from "@/lib/notifications";
import type { ChatRow } from "./store";

/** A follower that looked this recently counts as looking. */
export const SEEN_WINDOW_MS = 60_000;

export function notifyAfterMs(): number {
  const n = Number(process.env.ASSISTANT_NOTIFY_AFTER_SECONDS);
  return (Number.isFinite(n) && n >= 0 ? n : 30) * 1000;
}

/** Notifies about a finished turn if it is worth it; true when a message went out. */
export async function notifyTurnFinished(
  db: Db,
  chat: ChatRow,
  info: { startedAt: number; outcome: "answered" | "failed" | "stopped" },
  opts: { now?: number; send?: Sender; afterMs?: number } = {},
): Promise<boolean> {
  const now = opts.now ?? Date.now();
  if (info.outcome === "stopped") return false;
  if (now - info.startedAt < (opts.afterMs ?? notifyAfterMs())) return false;
  const seen = chat.seen_at ? Date.parse(chat.seen_at) : 0;
  if (now - seen < SEEN_WINDOW_MS) return false;
  const t = translator(familyLocale(db, chat.family_id));
  const page = typeof chat.context?.page === "string" ? chat.context.page : "overview";
  const path = page === "overview" ? "" : `/${page}`;
  const res = await notifyEvent(
    db,
    chat.family_id,
    "assistant_turn_finished",
    {
      title: t(info.outcome === "failed" ? "notifications.assistant.failed" : "notifications.assistant.title"),
      body: chat.title || t("notifications.assistant.untitled"),
      url: `${getAppUrl()}/f/${chat.family_id}${path}`,
    },
    { send: opts.send },
  );
  return !!res && res.sent > 0;
}
