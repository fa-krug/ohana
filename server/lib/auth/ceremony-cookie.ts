import { cookies } from "@/lib/http/request-context";
import { CEREMONY_COOKIE, cookieSecure, CEREMONY_TTL_MS, getAuthSecret } from "./config";
import { type CeremonyState, decodeCeremony, encodeCeremony } from "./ceremony";

export async function setCeremonyCookie(state: CeremonyState): Promise<void> {
  cookies().set(CEREMONY_COOKIE, encodeCeremony(state, getAuthSecret()), {
    httpOnly: true,
    sameSite: "lax",
    secure: cookieSecure(),
    path: "/",
    maxAge: Math.floor(CEREMONY_TTL_MS / 1000),
  });
}

export async function readCeremonyCookie(): Promise<CeremonyState | null> {
  const raw = cookies().get(CEREMONY_COOKIE)?.value;
  return raw ? decodeCeremony(raw, getAuthSecret()) : null;
}

export async function clearCeremonyCookie(): Promise<void> {
  cookies().delete(CEREMONY_COOKIE);
}
