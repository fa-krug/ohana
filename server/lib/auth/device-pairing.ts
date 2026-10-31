// Pairing the native app (apple/): it opens /device/pair?state=…&deviceName=… in a browser
// sheet (ASWebAuthenticationSession), the user signs in as usual (passkey or password, the
// login page follows `next`) and confirms; the page then hands an API token to the app through
// its URL scheme, ohana://auth-callback?token=…&state=…. `state` is the app's own random secret,
// echoed back unchanged, so a callback the app didn't ask for is refused there.

import type { Db } from "@/lib/db";
import { createToken } from "./tokens";
import { AuthError } from "./errors";
import { DEVICE_CALLBACK } from "./device-callback";

const STATE_RE = /^[A-Za-z0-9-]{8,128}$/;

export function validPairState(state: unknown): state is string {
  return typeof state === "string" && STATE_RE.test(state);
}

/** The token's name: the device's name, trimmed to something the token list can show. */
export function deviceTokenName(deviceName: unknown): string {
  const name = typeof deviceName === "string" ? deviceName.replace(/\s+/g, " ").trim().slice(0, 60) : "";
  return name ? `${name} (app)` : "Ohana app";
}

/** A new API token for the device and the URL that gives it to the app. */
export function pairDevice(
  db: Db,
  userId: string,
  args: { state: string; deviceName?: string },
  now: Date,
): { callbackUrl: string } {
  if (!validPairState(args.state)) throw new AuthError(400, "Invalid pairing request.");
  const { token } = createToken(db, { userId, kind: "api", name: deviceTokenName(args.deviceName) }, now);
  const q = new URLSearchParams({ token, state: args.state });
  return { callbackUrl: `${DEVICE_CALLBACK}?${q}` };
}

/** Where the login page may send the user afterwards: only a path of this site. */
export function safeNext(next: unknown): string | null {
  if (typeof next !== "string" || !next.startsWith("/") || next.startsWith("//") || next.includes("\\")) return null;
  return next;
}
