import { webcrypto } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import { SecretBox, deriveKey, devSecret, getSecretBox, isSealed } from "@/lib/secrets";

describe("SecretBox", () => {
  const box = new SecretBox(devSecret());

  it("seals and opens", () => {
    const sealed = box.seal("o.abc123");
    expect(sealed).toMatch(/^v1:/);
    expect(sealed).not.toContain("abc123");
    expect(isSealed(sealed)).toBe(true);
    expect(box.open(sealed)).toBe("o.abc123");
  });

  it("uses a fresh IV per seal", () => {
    expect(box.seal("x")).not.toBe(box.seal("x"));
  });

  it("keeps empty as empty", () => {
    expect(box.seal("")).toBe("");
    expect(box.open("")).toBe("");
  });

  it("rejects another key, tampering and unknown formats", () => {
    const sealed = box.seal("secret");
    expect(() => new SecretBox(devSecret()).open(sealed)).toThrow();
    const bytes = Buffer.from(sealed.slice(3), "base64");
    bytes[14] ^= 1;
    expect(() => box.open(`v1:${bytes.toString("base64")}`)).toThrow();
    expect(() => box.open("plain")).toThrow(/format/);
  });

  it("rejects keys that aren't 32 bytes", () => {
    expect(() => new SecretBox(Buffer.alloc(16).toString("base64"))).toThrow(/32 bytes/);
  });

  it("opens values sealed by family-planner's WebCrypto SecretBox", async () => {
    const raw = webcrypto.getRandomValues(new Uint8Array(32));
    const key = await webcrypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt"]);
    const iv = webcrypto.getRandomValues(new Uint8Array(12));
    const data = new Uint8Array(await webcrypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode("sk-legacy")));
    const sealed = "v1:" + Buffer.concat([iv, data]).toString("base64");
    expect(new SecretBox(Buffer.from(raw).toString("base64")).open(sealed)).toBe("sk-legacy");
  });
});

describe("getSecretBox", () => {
  const saved = { key: process.env.ENCRYPTION_KEY, auth: process.env.AUTH_SECRET };
  afterEach(() => {
    if (saved.key === undefined) delete process.env.ENCRYPTION_KEY;
    else process.env.ENCRYPTION_KEY = saved.key;
    if (saved.auth === undefined) delete process.env.AUTH_SECRET;
    else process.env.AUTH_SECRET = saved.auth;
  });

  it("derives the key from AUTH_SECRET with HKDF when ENCRYPTION_KEY is unset", () => {
    delete process.env.ENCRYPTION_KEY;
    process.env.AUTH_SECRET = "auth-secret-one";
    const sealed = getSecretBox().seal("tok");
    expect(SecretBox.fromKey(deriveKey("auth-secret-one")).open(sealed)).toBe("tok");
    process.env.AUTH_SECRET = "auth-secret-two";
    expect(() => getSecretBox().open(sealed)).toThrow();
  });

  it("prefers ENCRYPTION_KEY", () => {
    const key = devSecret();
    process.env.ENCRYPTION_KEY = key;
    process.env.AUTH_SECRET = "whatever";
    expect(new SecretBox(key).open(getSecretBox().seal("tok"))).toBe("tok");
  });
});
