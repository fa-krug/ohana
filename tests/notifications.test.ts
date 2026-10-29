import { eq } from "drizzle-orm";
import { beforeEach, describe, expect, it } from "vitest";
import type { Db } from "@/lib/db";
import * as schema from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";
import { CHANNEL_PROVIDERS, type ChannelInput, channelInputSchema, missingChannelFields } from "@/lib/notifications/schema";
import { createChannel, deleteChannel, listChannels, updateChannel } from "@/lib/notifications/channels";
import { type Channel, type Message, notifyFamily, sendTestNotification } from "@/lib/notifications";
import { plainEmail } from "@/lib/notifications/send";
import { getSecretBox } from "@/lib/secrets";

const base: ChannelInput = {
  name: "c", provider: "EMAIL", token: "", target: "", smtpHost: "", smtpPort: 465, smtpUsername: "", smtpFrom: "", enabled: true,
};
const pushbullet = (over: Partial<ChannelInput> = {}): ChannelInput => ({ ...base, name: "Phone", provider: "PUSHBULLET", token: "tok", ...over });

describe("channel schema", () => {
  it("includes the EMAIL provider", () => expect(CHANNEL_PROVIDERS).toContain("EMAIL"));

  it("parses an EMAIL channel and defaults the port to 465", () => {
    const parsed = channelInputSchema.parse({ name: "Mail", provider: "EMAIL", token: "secret", target: "me@example.com", smtpHost: "smtp.strato.de", smtpUsername: "fma@fa-krug.de" });
    expect(parsed.smtpPort).toBe(465);
    expect(parsed.smtpHost).toBe("smtp.strato.de");
  });

  it("coerces a string port", () => {
    expect(channelInputSchema.parse({ name: "Mail", provider: "EMAIL", smtpPort: "587" }).smtpPort).toBe(587);
  });
});

describe("missingChannelFields", () => {
  it("flags every missing EMAIL field", () => {
    expect(missingChannelFields(base).sort()).toEqual(["smtpHost", "smtpUsername", "target", "token"]);
  });
  it("passes a complete EMAIL channel", () => {
    expect(missingChannelFields({ ...base, token: "pw", target: "me@example.com", smtpHost: "smtp.strato.de", smtpUsername: "u" })).toEqual([]);
  });
  it("flags a PUSHBULLET channel missing its token", () => {
    expect(missingChannelFields({ ...base, provider: "PUSHBULLET" })).toEqual(["token"]);
  });
});

describe("channels", () => {
  let db: Db;
  let editor: { id: string };
  let viewer: { id: string };
  let family: { id: string };

  beforeEach(() => {
    db = createTestDb();
    editor = makeUser(db);
    viewer = makeUser(db);
    family = makeFamily(db, editor.id, [{ userId: viewer.id, role: "viewer" }]);
  });

  it("stores the token sealed and never lists it", () => {
    const { id } = createChannel(db, editor, family.id, pushbullet(), NOW);
    const row = db.select().from(schema.notificationChannels).where(eq(schema.notificationChannels.id, id)).get()!;
    expect(row.token).toMatch(/^v1:/);
    expect(getSecretBox().open(row.token)).toBe("tok");
    const [dto] = listChannels(db, viewer, family.id);
    expect(dto).toMatchObject({ id, name: "Phone", hasToken: true });
    expect(JSON.stringify(dto)).not.toContain("v1:");
    expect(dto).not.toHaveProperty("token");
  });

  it("keeps the stored token when the edit leaves it blank, replaces it otherwise", () => {
    const { id } = createChannel(db, editor, family.id, pushbullet(), NOW);
    const token = () => getSecretBox().open(db.select().from(schema.notificationChannels).where(eq(schema.notificationChannels.id, id)).get()!.token);
    updateChannel(db, editor, family.id, id, pushbullet({ name: "Renamed", token: "" }));
    expect(token()).toBe("tok");
    updateChannel(db, editor, family.id, id, pushbullet({ token: "new" }));
    expect(token()).toBe("new");
  });

  it("validates required fields", () => {
    expect(() => createChannel(db, editor, family.id, pushbullet({ token: "" }), NOW)).toThrow(/token is required/);
  });

  it("only editors change channels; other families see nothing", () => {
    expect(() => createChannel(db, viewer, family.id, pushbullet(), NOW)).toThrow(AuthError);
    const { id } = createChannel(db, editor, family.id, pushbullet(), NOW);
    expect(() => deleteChannel(db, viewer, family.id, id)).toThrow(/editors/);
    const stranger = makeUser(db);
    const theirs = makeFamily(db, stranger.id);
    expect(() => listChannels(db, stranger, family.id)).toThrow(/not found/);
    expect(() => deleteChannel(db, stranger, theirs.id, id)).toThrow(/not found/);
    deleteChannel(db, editor, family.id, id);
    expect(listChannels(db, editor, family.id)).toEqual([]);
  });

  describe("notifyFamily", () => {
    const msg: Message = { title: "T", body: "B", url: "https://ohana.test" };

    it("sends to every enabled channel, or the chosen ones; [] sends nothing", async () => {
      const a = createChannel(db, editor, family.id, pushbullet({ name: "A", token: "ta" }), NOW).id;
      createChannel(db, editor, family.id, pushbullet({ name: "B", token: "tb" }), NOW);
      createChannel(db, editor, family.id, pushbullet({ name: "Off", enabled: false }), NOW);
      const got: string[] = [];
      const send = async (c: Channel) => void got.push(c.token);
      expect(await notifyFamily(db, family.id, msg, { send })).toEqual({ sent: 2, failed: 0 });
      expect(got.sort()).toEqual(["ta", "tb"]);
      got.length = 0;
      expect(await notifyFamily(db, family.id, msg, { send, channelIds: [a] })).toEqual({ sent: 1, failed: 0 });
      expect(got).toEqual(["ta"]);
      expect(await notifyFamily(db, family.id, msg, { send, channelIds: [] })).toEqual({ sent: 0, failed: 0 });
    });

    it("counts a failing channel without stopping the others", async () => {
      createChannel(db, editor, family.id, pushbullet({ name: "A", token: "bad" }), NOW);
      createChannel(db, editor, family.id, pushbullet({ name: "B", token: "good" }), NOW);
      const send = async (c: Channel) => {
        if (c.token === "bad") throw new Error("401");
      };
      expect(await notifyFamily(db, family.id, msg, { send })).toEqual({ sent: 1, failed: 1 });
    });

    it("treats a token sealed with another key as a failed channel", async () => {
      const { id } = createChannel(db, editor, family.id, pushbullet(), NOW);
      db.update(schema.notificationChannels).set({ token: "v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }).where(eq(schema.notificationChannels.id, id)).run();
      const send = async () => undefined;
      expect(await notifyFamily(db, family.id, msg, { send })).toEqual({ sent: 0, failed: 1 });
    });
  });

  it("sends a test message in the family's language, also to a disabled channel", async () => {
    db.update(schema.users).set({ preferredLanguage: "de" }).where(eq(schema.users.id, editor.id)).run();
    const { id } = createChannel(db, editor, family.id, pushbullet({ enabled: false, name: "Handy" }), NOW);
    const got: Message[] = [];
    await sendTestNotification(db, editor, family.id, id, { send: async (_c, m) => void got.push(m) });
    expect(got[0].body).toContain("„Handy“");
    await expect(sendTestNotification(db, editor, family.id, id, { send: async () => { throw new Error("401 Unauthorized"); } })).rejects.toThrow(/401/);
    await expect(sendTestNotification(db, viewer, family.id, id)).rejects.toThrow(/editors/);
  });
});

describe("plainEmail", () => {
  it("escapes and links", () => {
    const { html, text } = plainEmail({ title: "<b>", body: "a\nb", url: "https://x" });
    expect(html).toContain("&lt;b&gt;");
    expect(html).toContain("a<br>b");
    expect(text).toContain("https://x");
  });
});
