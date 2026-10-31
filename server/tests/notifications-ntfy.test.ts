// The ntfy channel: saving (topic URL required, token optional and sealed) and the request.

import { describe, expect, it } from "vitest";
import { createChannel, listChannels, openChannels } from "@/lib/notifications/channels";
import { validNtfyTopicUrl } from "@/lib/notifications/schema";
import { ntfyRequest } from "@/lib/notifications/send";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

function setup() {
  const db = createTestDb();
  const user = makeUser(db, { email: "anna@test" });
  const family = makeFamily(db, user.id);
  return { db, actor: { id: user.id }, familyId: family.id };
}

const base = { smtpHost: "", smtpPort: 465, smtpUsername: "", smtpFrom: "", enabled: true };

describe("ntfy channels", () => {
  it("checks the topic URL", () => {
    expect(validNtfyTopicUrl("https://ntfy.sh/family-news")).toBe(true);
    expect(validNtfyTopicUrl("http://192.168.1.5:8080/ohana")).toBe(true);
    expect(validNtfyTopicUrl("https://ntfy.sh/")).toBe(false);
    expect(validNtfyTopicUrl("ftp://ntfy.sh/x")).toBe(false);
    expect(validNtfyTopicUrl("https://user:pw@ntfy.sh/x")).toBe(false);
    expect(validNtfyTopicUrl("family-news")).toBe(false);
  });

  it("saves one without a token, refuses one without a topic URL", () => {
    const { db, actor, familyId } = setup();
    expect(() => createChannel(db, actor, familyId, { ...base, name: "Phones", provider: "NTFY", token: "", target: "" }, NOW)).toThrow(/target is required/);
    expect(() => createChannel(db, actor, familyId, { ...base, name: "Phones", provider: "NTFY", token: "", target: "not a url" }, NOW)).toThrow(/topic URL/);
    createChannel(db, actor, familyId, { ...base, name: "Phones", provider: "NTFY", token: "", target: "https://ntfy.sh/family" }, NOW);
    expect(listChannels(db, actor, familyId)).toMatchObject([{ name: "Phones", provider: "NTFY", target: "https://ntfy.sh/family", hasToken: false }]);
  });

  it("keeps the access token sealed and opens it for sending", () => {
    const { db, actor, familyId } = setup();
    createChannel(db, actor, familyId, { ...base, name: "Phones", provider: "NTFY", token: "tk_secret", target: "https://ntfy.example/family" }, NOW);
    expect(listChannels(db, actor, familyId)[0]).toMatchObject({ hasToken: true });
    expect(JSON.stringify(listChannels(db, actor, familyId))).not.toContain("tk_secret");
    expect(openChannels(db, familyId)[0]).toMatchObject({ provider: "NTFY", token: "tk_secret" });
  });

  it("publishes title, body and link, with the token as bearer", () => {
    const channel = { provider: "NTFY", token: "tk", target: "https://ntfy.sh/family", smtpHost: "", smtpPort: 0, smtpUsername: "", smtpFrom: "" };
    const { url, init } = ntfyRequest(channel, { title: "Shopping tomorrow", body: "Milk", url: "https://ohana.example/f/1" });
    expect(url).toBe("https://ntfy.sh/family");
    expect(init.method).toBe("POST");
    expect(init.body).toBe("Milk");
    expect(init.headers).toMatchObject({ Title: "Shopping tomorrow", Click: "https://ohana.example/f/1", Authorization: "Bearer tk" });
  });

  it("encodes a title that isn't ASCII, sends no token header without one", () => {
    const channel = { provider: "NTFY", token: "", target: "https://ntfy.sh/family", smtpHost: "", smtpPort: 0, smtpUsername: "", smtpFrom: "" };
    const { init } = ntfyRequest(channel, { title: "Einkauf für morgen", body: "", url: "" });
    const headers = init.headers as Record<string, string>;
    expect(headers.Title).toBe(`=?UTF-8?B?${Buffer.from("Einkauf für morgen").toString("base64")}?=`);
    expect(headers.Authorization).toBeUndefined();
    expect(headers.Click).toBeUndefined();
    expect(init.body).toBe("Einkauf für morgen");
  });
});
