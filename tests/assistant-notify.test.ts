// "Assistant turn finished" (phase 7's notifications, phase 3 part B): a turn that ran for a
// while and ended while nobody followed the chat is told to the family's channels for the
// event (off by default). Following a chat marks it as seen; the worker reports each turn's end.

import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import { notifyTurnFinished } from "@/lib/assistant/notify";
import type { ChatRow } from "@/lib/assistant/store";
import { chats } from "@/lib/db/schema";
import { createChannel } from "@/lib/notifications/channels";
import type { Channel, Message } from "@/lib/notifications";
import { setPref } from "@/lib/notifications/prefs";
import { type AssistantTest, assistantTest, configure } from "@/lib/test/assistant";
import { NOW } from "@/lib/test/factories";

let current: AssistantTest[] = [];
afterEach(async () => {
  await Promise.all(current.map((t) => t.stop()));
  current = [];
});

const sent: Message[] = [];
const send = async (_c: Channel, msg: Message) => void sent.push(msg);

function setup(env: Parameters<typeof assistantTest>[0] = {}) {
  const t = assistantTest(env);
  current.push(t);
  createChannel(
    t.db,
    { id: t.editor.id },
    t.familyId,
    { name: "Phone", provider: "PUSHBULLET", token: "tok", target: "", smtpHost: "", smtpPort: 465, smtpUsername: "", smtpFrom: "", enabled: true },
    NOW,
  );
  sent.length = 0;
  return t;
}

const T0 = Date.parse("2026-11-01T12:00:00Z");
function chat(t: AssistantTest, over: Partial<ChatRow> = {}): ChatRow {
  return {
    id: "c1",
    family_id: t.familyId,
    user_id: t.editor.id,
    title: "Plan next week",
    status: "idle",
    run_token: null,
    run_until: null,
    stop: false,
    retries: 0,
    context: { page: "meals" },
    activity: null,
    notes: [],
    usage: null,
    queue: [],
    rev: 1,
    seen_at: null,
    created_at: NOW.toISOString(),
    updated_at: NOW.toISOString(),
    ...over,
  };
}

describe("notifyTurnFinished", () => {
  it("is off by default; on, it tells long turns nobody watched", async () => {
    const t = setup({ worker: false });
    const long = { startedAt: T0, outcome: "answered" as const };
    const now = T0 + 45_000;
    expect(await notifyTurnFinished(t.db, chat(t), long, { now, send, afterMs: 30_000 })).toBe(false);
    setPref(t.db, { id: t.editor.id }, t.familyId, { event: "assistant_turn_finished", enabled: true, channelIds: null }, NOW);
    expect(await notifyTurnFinished(t.db, chat(t), long, { now, send, afterMs: 30_000 })).toBe(true);
    expect(sent).toEqual([
      { title: "The assistant has answered", body: "Plan next week", url: expect.stringMatching(new RegExp(`/f/${t.familyId}/meals$`)) },
    ]);
    // A failed turn says so.
    await notifyTurnFinished(t.db, chat(t, { title: "" }), { ...long, outcome: "failed" }, { now, send, afterMs: 30_000 });
    expect(sent.at(-1)).toMatchObject({ title: "The assistant couldn't finish", body: "Your chat" });
    sent.length = 0;
    // Short turns, stopped turns and chats someone looked at in the last minute: nothing.
    expect(await notifyTurnFinished(t.db, chat(t), { ...long, startedAt: now - 10_000 }, { now, send, afterMs: 30_000 })).toBe(false);
    expect(await notifyTurnFinished(t.db, chat(t), { ...long, outcome: "stopped" }, { now, send, afterMs: 30_000 })).toBe(false);
    const seen = new Date(now - 20_000).toISOString();
    expect(await notifyTurnFinished(t.db, chat(t, { seen_at: seen }), long, { now, send, afterMs: 30_000 })).toBe(false);
    const old = new Date(now - 90_000).toISOString();
    expect(await notifyTurnFinished(t.db, chat(t, { seen_at: old }), long, { now, send, afterMs: 30_000 })).toBe(true);
    expect(sent).toHaveLength(1);
  });
});

describe("in the worker", () => {
  it("following a chat marks it as seen, and every finished turn is reported", async () => {
    const ended: { outcome: string; seen: string | null | undefined }[] = [];
    const t = setup({
      env: {
        turnEnded: async (c, info) => {
          ended.push({ outcome: info.outcome, seen: c.seen_at });
        },
      },
    });
    await configure(t);
    const res = await t.call("POST", `${t.ai}/chats`, { text: "hello", today: "2026-11-01", year: 2026, lang: "en", page: "overview" });
    expect(res.status).toBe(200);
    for (let i = 0; i < 100 && !ended.length; i++) await new Promise((r) => setTimeout(r, 10));
    expect(ended).toHaveLength(1);
    expect(ended[0].outcome).toBe("answered");
    const row = t.db.select().from(chats).get()!;
    expect(row.seenAt).not.toBeNull();
    // The stream that followed the turn marked it while it ran.
    expect(ended[0].seen).not.toBeNull();
    expect(row.id).toBe((await t.store.listChats(t.familyId, t.editor.id))[0].id);
    expect(t.db.select().from(chats).where(eq(chats.id, row.id)).get()!.status).toBe("idle");
  });
});
