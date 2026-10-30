// Joining a family with an invite from the native app (apple/), under /api/v1/invites/...:
// what the web's /invite/{code} page shows and its "Accept invite" (acceptInviteAction) does,
// for the API token's account.
//
// GET  /invites/{code}          → {familyId, familyName, role, personName, expiresAt, alreadyMember}
// POST /invites/{code}/accept   → the family as GET /api/v1/me lists it

import type { Db } from "@/lib/db";
import { type AppRoutes, runAppRoutes } from "@/lib/api/app-router";
import { getInviteSummary, acceptInvite, validateInvite } from "./invites";
import { listFamiliesOf } from "./manage";
import { getRole, isRole } from "./roles";

const routes: AppRoutes = [
  [
    ["*"],
    {
      GET: (c, [code]) => {
        const invite = validateInvite(c.db, code, c.now);
        const { familyName, personName, expiresAt } = getInviteSummary(c.db, code, c.now);
        return {
          familyId: invite.familyId,
          familyName,
          role: isRole(invite.role) ? invite.role : "viewer",
          personName,
          expiresAt,
          alreadyMember: getRole(c.db, invite.familyId, c.user.id) !== null,
        };
      },
    },
  ],
  [
    ["*", "accept"],
    {
      POST: (c, [code]) => {
        const { familyId } = c.db.transaction((tx) => acceptInvite(tx as unknown as Db, c.user.id, code, c.now));
        return listFamiliesOf(c.db, c.user.id).find((f) => f.id === familyId);
      },
    },
  ],
];

/** /api/v1/invites/{path…} for the app. */
export function handleInvitesApp(db: Db, req: Request, path: string[], now?: Date): Promise<Response> {
  return runAppRoutes(routes, db, req, path, { now });
}
