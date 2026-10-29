import { db } from "@/lib/db";
import { listChannelRows } from "@/lib/notifications/channels";

/** The family's channels as the search form offers them (no secrets). */
export function channelOptions(familyId: string) {
  return listChannelRows(db, familyId).map((c) => ({ id: c.id, name: c.name, provider: c.provider, enabled: c.enabled }));
}
