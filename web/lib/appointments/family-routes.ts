// Appointment routes of the family API (/api/v1/families/{id}/appointments/searches/{id}), for
// editors: what the assistant's undo steps call (the pages use server actions).
//   PATCH  /appointments/searches/{id}   puts a search back (a SearchInput)
//   DELETE /appointments/searches/{id}   deletes a search

import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import { searchInputSchema } from "./schema";
import { deleteSearch, updateSearch } from "./searches";

export function handleAppointments(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] !== "appointments" || ctx.rest[1] !== "searches") return null;
  const id = ctx.rest[2];
  if (id === undefined || ctx.rest.length > 3) return Promise.reject(new HttpError(404, "Not found"));
  if (ctx.method === "PATCH") {
    return (async () => {
      const { family } = await ctx.load("edit");
      const user = ctx.requireUser();
      const input = searchInputSchema.parse(await readBody(ctx.req));
      updateSearch(ctx.db, { id: user.id }, family.id, id, input, ctx.now);
      return json({ id });
    })();
  }
  if (ctx.method === "DELETE") {
    return (async () => {
      const { family } = await ctx.load("edit");
      deleteSearch(ctx.db, { id: ctx.requireUser().id }, family.id, id);
      return json({ deleted: id });
    })();
  }
  return Promise.reject(new HttpError(405, "Method not allowed"));
}
