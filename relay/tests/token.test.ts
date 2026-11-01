import { createCipheriv, randomBytes } from "node:crypto";
import { openToken, sealToken, type Device } from "../src/token";
import { newSecrets } from "./helpers";

const device: Device = { apnsToken: "ab".repeat(32), environment: "sandbox", platform: "macos", issuedAt: 1_790_000_000 };

/** Seals arbitrary plaintext the way sealToken does. */
function sealRaw(key: Buffer, plain: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const data = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  return "r1." + Buffer.concat([iv, data, cipher.getAuthTag()]).toString("base64url");
}

describe("relay tokens", () => {
  it("seal and open", () => {
    const secrets = newSecrets();
    const token = sealToken(secrets, device);
    expect(token).toMatch(/^r1\.[A-Za-z0-9_-]+$/);
    expect(openToken(secrets, token)).toEqual(device);
  });

  it("hold the documented JSON: 12-byte IV, ciphertext, 16-byte tag", () => {
    const secrets = newSecrets();
    const bytes = Buffer.from(sealToken(secrets, device).slice(3), "base64url");
    const plain = JSON.stringify({ t: device.apnsToken, e: "sandbox", p: "macos", iat: device.issuedAt });
    expect(bytes.length).toBe(12 + Buffer.byteLength(plain) + 16);
    // Anyone with the secret can build one (e.g. the server's tests): same format opens.
    expect(openToken(secrets, sealRaw(secrets.current, plain))).toEqual(device);
  });

  it("use a fresh IV every time", () => {
    const secrets = newSecrets();
    expect(sealToken(secrets, device)).not.toBe(sealToken(secrets, device));
  });

  it("don't open when tampered with", () => {
    const secrets = newSecrets();
    const token = sealToken(secrets, device);
    const bytes = Buffer.from(token.slice(3), "base64url");
    for (const i of [0, 12, 20, bytes.length - 1]) {
      const changed = Buffer.from(bytes);
      changed[i] ^= 1;
      expect(openToken(secrets, "r1." + changed.toString("base64url"))).toBeNull();
    }
    expect(openToken(secrets, token.replace("r1.", "r2."))).toBeNull();
    expect(openToken(secrets, token + "!")).toBeNull();
    expect(openToken(secrets, "r1.")).toBeNull();
    expect(openToken(secrets, "r1.AAAA")).toBeNull();
    expect(openToken(secrets, "")).toBeNull();
  });

  it("don't open with another secret", () => {
    expect(openToken(newSecrets(), sealToken(newSecrets(), device))).toBeNull();
  });

  it("open with RELAY_SECRET_OLD while rotating, but new ones are sealed with the current one", () => {
    const before = newSecrets();
    const old = sealToken(before, device);
    const rotating = { current: randomBytes(32), old: before.current };
    expect(openToken(rotating, old)).toEqual(device);
    const fresh = sealToken(rotating, device);
    expect(openToken({ current: rotating.current }, fresh)).toEqual(device);
    expect(openToken(before, fresh)).toBeNull();
    // Once the old secret is gone, its tokens don't open any more.
    expect(openToken({ current: rotating.current }, old)).toBeNull();
  });

  it("reject sealed content that isn't a device", () => {
    const secrets = newSecrets();
    const bad = [
      "not json",
      "[]",
      JSON.stringify({ t: "xyz", e: "production", p: "ios", iat: 1 }),
      JSON.stringify({ t: "a".repeat(64), e: "staging", p: "ios", iat: 1 }),
      JSON.stringify({ t: "a".repeat(64), e: "production", p: "android", iat: 1 }),
      JSON.stringify({ t: "a".repeat(64), e: "production", p: "ios" }),
    ];
    for (const plain of bad) expect(openToken(secrets, sealRaw(secrets.current, plain))).toBeNull();
  });
});
