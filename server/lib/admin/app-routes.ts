// The administration routes of the native app (apple/), under /api/v1/admin/...: what the
// web's admin pages do with server actions (app/actions/admin.ts), with the same lib
// functions. Administrators only; everyone else gets 404, like the pages.
//
// GET    /admin/users                              → {users: AdminUserDto[]}
// POST   /admin/users {email, name, isAdmin}       → {userId, setupUrl, expiresAt}
// PATCH  /admin/users/{id} {email?, name?, isAdmin?}
// DELETE /admin/users/{id}                         (not oneself)
// POST   /admin/users/{id}/setup-link              → {setupUrl, expiresAt} (signs them out)
// GET    /admin/families                           → {families: AdminFamilyDto[]}
// POST   /admin/families {name}                    → {id}
// PATCH  /admin/families/{id} {name}
// DELETE /admin/families/{id}
// POST   /admin/families/{id}/members {email, role}
// PATCH  /admin/families/{id}/members/{userId} {role}
// DELETE /admin/families/{id}/members/{userId}     (a family keeps an editor)

import type { Db } from "@/lib/db";
import { type AppCtx, type AppRoutes, runAppRoutes } from "@/lib/api/app-router";
import { createFamily, deleteFamily, renameFamily } from "@/lib/families/manage";
import { addMember, removeMember, setRole } from "@/lib/families/members";
import type { Actor } from "@/lib/families/roles";
import { pickLocale } from "@/lib/i18n/locale";
import { addMemberSchema, adminUserSchema, adminUserUpdateSchema, familyNameSchema, role } from "@/lib/schemas/auth";
import { listAllFamilies } from "./families";
import { createUser, deleteUser, listUsers, resetUser, updateUser } from "./users";

const actor = (c: AppCtx): Actor => ({ id: c.user.id, admin: true });

const routes: AppRoutes = [
  [
    ["users"],
    {
      GET: (c) => ({ users: listUsers(c.db) }),
      POST: async (c) => createUser(c.db, adminUserSchema.parse(await c.body()), c.now),
    },
  ],
  [
    ["users", "*"],
    {
      PATCH: async (c, [id]) => {
        updateUser(c.db, c.user.id, id, adminUserUpdateSchema.parse(await c.body()));
      },
      DELETE: (c, [id]) => {
        deleteUser(c.db, c.user.id, id);
      },
    },
  ],
  [["users", "*", "setup-link"], { POST: (c, [id]) => resetUser(c.db, id, c.now) }],
  [
    ["families"],
    {
      GET: (c) => ({ families: listAllFamilies(c.db) }),
      POST: async (c) => {
        const { name } = familyNameSchema.parse(await c.body());
        // The calendar's preset types and the categories are named in the admin's language.
        const lang = pickLocale([c.user.preferredLanguage, c.req.headers.get("accept-language")?.split(",")[0]]);
        return { id: createFamily(c.db, { name, lang }, c.now).id };
      },
    },
  ],
  [
    ["families", "*"],
    {
      PATCH: async (c, [id]) => {
        renameFamily(c.db, actor(c), id, familyNameSchema.parse(await c.body()).name, c.now);
      },
      DELETE: (c, [id]) => {
        deleteFamily(c.db, actor(c), id);
      },
    },
  ],
  [
    ["families", "*", "members"],
    {
      POST: async (c, [id]) => {
        addMember(c.db, actor(c), id, addMemberSchema.parse(await c.body()), c.now);
      },
    },
  ],
  [
    ["families", "*", "members", "*"],
    {
      PATCH: async (c, [id, userId]) => {
        setRole(c.db, actor(c), id, userId, role.parse((await c.body()).role));
      },
      DELETE: (c, [id, userId]) => {
        removeMember(c.db, actor(c), id, userId);
      },
    },
  ],
];

/** /api/v1/admin/{path…} for the app. */
export function handleAdminApp(db: Db, req: Request, path: string[], now?: Date): Promise<Response> {
  return runAppRoutes(routes, db, req, path, { now, admin: true });
}
