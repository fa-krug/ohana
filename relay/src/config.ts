// The relay's settings, read once at startup from the environment. A missing or malformed
// required value stops the process with a message that names it (better than failing at the
// first push).

import { createPrivateKey, type KeyObject } from "node:crypto";
import type { Secrets } from "./token";

export type Config = {
  port: number;
  apns: {
    key: KeyObject;
    keyId: string;
    teamId: string;
    topic: string;
  };
  secrets: Secrets;
  trustProxy: boolean;
};

export class ConfigError extends Error {}

type Env = Record<string, string | undefined>;

/** Reads and checks the environment; throws ConfigError naming each problem. */
export function loadConfig(env: Env = process.env): Config {
  const problems: string[] = [];
  const required = (name: string): string => {
    const value = env[name]?.trim();
    if (!value) problems.push(`${name} is required`);
    return value ?? "";
  };

  const portText = env.PORT?.trim() || "8080";
  const port = Number(portText);
  if (!/^\d+$/.test(portText) || port < 1 || port > 65535) problems.push("PORT must be a port number");

  const keyText = required("APNS_KEY");
  let key: KeyObject | null = null;
  if (keyText) {
    try {
      key = parseApnsKey(keyText);
    } catch (err) {
      problems.push(`APNS_KEY: ${(err as Error).message}`);
    }
  }

  const keyId = required("APNS_KEY_ID");
  if (keyId && !/^[A-Z0-9]{10}$/.test(keyId)) problems.push("APNS_KEY_ID must be the key's 10-character id");
  const teamId = required("APNS_TEAM_ID");
  if (teamId && !/^[A-Z0-9]{10}$/.test(teamId)) problems.push("APNS_TEAM_ID must be the 10-character team id");
  const topic = env.APNS_TOPIC?.trim() || "de.fa-krug.Ohana";

  const current = parseSecret("RELAY_SECRET", required("RELAY_SECRET"), problems);
  const oldText = env.RELAY_SECRET_OLD?.trim();
  const old = oldText ? parseSecret("RELAY_SECRET_OLD", oldText, problems) : undefined;

  if (problems.length > 0 || !key || !current) {
    throw new ConfigError(`Invalid configuration:\n  - ${problems.join("\n  - ")}`);
  }
  return {
    port,
    apns: { key, keyId, teamId, topic },
    secrets: { current, old: old ?? undefined },
    trustProxy: env.TRUST_PROXY?.trim() === "1",
  };
}

/** The .p8 file's PEM text (a literal "\n" counts as a line break, for one-line env files). */
export function parseApnsKey(text: string): KeyObject {
  const pem = text.replace(/\\n/g, "\n").trim();
  let key: KeyObject;
  try {
    key = createPrivateKey({ key: pem, format: "pem" });
  } catch {
    throw new Error("not a PEM private key (paste the whole .p8 file, BEGIN and END lines included)");
  }
  if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
    throw new Error("not a P-256 key (APNs auth keys are)");
  }
  return key;
}

function parseSecret(name: string, text: string, problems: string[]): Buffer | null {
  if (!text) return null;
  const bytes = Buffer.from(text, "base64");
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(text) || bytes.length !== 32) {
    problems.push(`${name} must be 32 bytes, base64-encoded (openssl rand -base64 32)`);
    return null;
  }
  return bytes;
}
