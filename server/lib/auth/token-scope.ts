// Agent tokens: API tokens scoped to one family (`auth_tokens.family_id`), minted by
// POST /families/{id}/agent/token for an outside AI agent (one hour). Such a token works only for
// the server's public info and that family's API; never for the account (/me: new tokens,
// password, email), the administration, invites, other families, new families or images.
//
// Inside the family it acts as the user, except for what `agentMayChange` holds back (members,
// invites, notification channels, the assistant's settings and memory, deleting the family).
//
// Enforced at one choke point, the /api middleware in http/api.ts (`refuseOutOfScope`, every
// request carrying a Bearer token), and again where each kind of route resolves its user:
// `apiAuth` (lib/api/app-router.ts: /me, /admin, /invites never take one), `getApiUser`
// (lib/auth/session.ts: only with the family it is asked for) and the family API's
// `authenticate` (lib/api/family-api.ts: the path's family only).

import { AuthError } from "./errors";
import type { AuthToken } from "./tokens";

export const AGENT_TOKEN_NAME = "AI agent";
export const AGENT_TOKEN_TTL_MS = 60 * 60 * 1000;
export const OUT_OF_SCOPE = "This token only works for the family's API.";
export const AGENT_HOLD = "An AI agent can't change this: members, invites, notification channels, the assistant's settings, the assistant's memory and deleting the family are done in the app.";

/** Whether a token may be used for the family `familyId` (null: anything outside a family). */
export function tokenAllowsFamily(token: Pick<AuthToken, "familyId">, familyId: string | null): boolean {
  return token.familyId == null || token.familyId === familyId;
}

/** Throws 403 unless the token may be used for `familyId` (null: outside a family). */
export function assertTokenScope(token: Pick<AuthToken, "familyId">, familyId: string | null): void {
  if (!tokenAllowsFamily(token, familyId)) throw new AuthError(403, OUT_OF_SCOPE);
}

/** Whether a request path (a URL's pathname) is one an agent token of `familyId` may reach:
 *  /api/health, /api/v1/server and /api/v1/families/{familyId}[/…]. Parts are compared decoded,
 *  as the routes see them. */
export function pathInScope(pathname: string, familyId: string): boolean {
  let parts: string[];
  try {
    parts = pathname.split("/").filter(Boolean).map(decodeURIComponent);
  } catch {
    return false;
  }
  const at = (...want: string[]) => want.every((w, i) => parts[i] === w);
  if (parts.length === 2 && at("api", "health")) return true;
  if (parts.length === 3 && at("api", "v1", "server")) return true;
  return parts.length >= 4 && at("api", "v1", "families", familyId);
}

/** Whether an agent token may make this request inside its family (`rest`: the path after the
 *  family's id). Reading is always allowed; what would outlast the token's hour or carry the
 *  family's data elsewhere is not changed by an agent: deleting the family, the members and
 *  people (a person can come with an invite), invites, notification channels and events, the
 *  assistant's settings (its endpoint would get every chat, and its model list and connection test
 *  call outside servers) and the assistant's memory (standing instructions it would follow in
 *  every chat). */
export function agentMayChange(method: string, rest: string[]): boolean {
  if (method === "GET" || method === "HEAD") return true;
  const [first, second] = rest;
  if (first === "household") {
    if (rest.length === 1) return false;
    return !["members", "people", "invites", "notifications"].includes(second);
  }
  if (first === "ai") return !["settings", "models", "test", "memories"].includes(second);
  return true;
}
