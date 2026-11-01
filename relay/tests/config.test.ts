import { generateKeyPairSync, randomBytes } from "node:crypto";
import { ConfigError, loadConfig } from "../src/config";

const pem = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
  .privateKey.export({ format: "pem", type: "pkcs8" })
  .toString();

const valid = {
  APNS_KEY: pem,
  APNS_KEY_ID: "ABC123DEFG",
  APNS_TEAM_ID: "HS26J3YA63",
  RELAY_SECRET: randomBytes(32).toString("base64"),
};

describe("loadConfig", () => {
  it("reads the environment with defaults", () => {
    const config = loadConfig(valid);
    expect(config.port).toBe(8080);
    expect(config.apns.topic).toBe("de.fa-krug.Ohana");
    expect(config.apns.keyId).toBe("ABC123DEFG");
    expect(config.secrets.current).toEqual(Buffer.from(valid.RELAY_SECRET, "base64"));
    expect(config.secrets.old).toBeUndefined();
    expect(config.trustProxy).toBe(false);
  });

  it("takes the optional ones", () => {
    const old = randomBytes(32).toString("base64");
    const config = loadConfig({ ...valid, PORT: "9000", APNS_TOPIC: "com.example.Fork", RELAY_SECRET_OLD: old, TRUST_PROXY: "1" });
    expect(config.port).toBe(9000);
    expect(config.apns.topic).toBe("com.example.Fork");
    expect(config.secrets.old).toEqual(Buffer.from(old, "base64"));
    expect(config.trustProxy).toBe(true);
  });

  it("accepts the key with literal \\n (one-line env files)", () => {
    expect(() => loadConfig({ ...valid, APNS_KEY: pem.trim().replace(/\n/g, "\\n") })).not.toThrow();
  });

  it("names every missing or malformed value", () => {
    expect(() => loadConfig({})).toThrow(ConfigError);
    try {
      loadConfig({});
    } catch (err) {
      for (const name of ["APNS_KEY", "APNS_KEY_ID", "APNS_TEAM_ID", "RELAY_SECRET"]) {
        expect((err as Error).message).toContain(`${name} is required`);
      }
    }
    const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({ format: "pem", type: "pkcs8" }).toString();
    const cases: [Record<string, string>, RegExp][] = [
      [{ APNS_KEY: "nope" }, /APNS_KEY: not a PEM private key/],
      [{ APNS_KEY: rsa }, /APNS_KEY: not a P-256 key/],
      [{ APNS_KEY_ID: "abc" }, /APNS_KEY_ID/],
      [{ APNS_TEAM_ID: "HS26J3YA6" }, /APNS_TEAM_ID/],
      [{ RELAY_SECRET: randomBytes(16).toString("base64") }, /RELAY_SECRET must be 32 bytes/],
      [{ RELAY_SECRET: "not base64!!" }, /RELAY_SECRET must be 32 bytes/],
      [{ RELAY_SECRET_OLD: "short" }, /RELAY_SECRET_OLD must be 32 bytes/],
      [{ PORT: "http" }, /PORT/],
    ];
    for (const [change, message] of cases) {
      expect(() => loadConfig({ ...valid, ...change })).toThrow(message);
    }
  });
});
