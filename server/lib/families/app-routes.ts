// Routes of the family API for the native app (apple/): the overview (/overview), the search
// across the modules (/search) and the household settings (/household/...: members, people
// without an account, invites, the home address, notification channels and events), which the
// web pages do with server actions.
// They call the same lib functions as those actions (same checks: viewers read, editors
// change, a family keeps an editor). Registered before the module's other routes; null for
// paths that aren't its own ("", links, export and import are handleFamily's).
//
// GET    /overview?today=YYYY-MM-DD            the dashboard (familyDashboard)
// GET    /search?q=&today=YYYY-MM-DD&limit=    one search across the modules (searchFamily)
// GET    /household                            everything the settings page shows
// DELETE /household                            deletes the family (editors; sole member)
// POST   /household/members {email, role}      adds an account by its sign-in name
// PATCH  /household/members/{userId} {role?, birthday?}
// DELETE /household/members/{userId}           removes a member (oneself: leave)
// POST   /household/people {name, birthday?, invite?: role | null}
// PATCH  /household/people/{id} {name, birthday}
// DELETE /household/people/{id}
// POST   /household/invites {role, personId?}
// DELETE /household/invites/{id}
// PUT    /household/home {address, lat, lng}    (an empty address clears it)
// POST   /household/notifications/channels {name, provider, token, target, smtp…, enabled}
// PATCH  /household/notifications/channels/{id} (a blank token keeps the stored one)
// DELETE /household/notifications/channels/{id}
// POST   /household/notifications/channels/{id}/test
// PUT    /household/notifications/events/{event} {enabled, channelIds: string[] | null}

import { eq } from "drizzle-orm";
import { z } from "zod";
import type { Ctx } from "@/lib/api/family-api";
import { HttpError, json, readBody } from "@/lib/api/http";
import type { Db } from "@/lib/db";
import { families } from "@/lib/db/schema";
import type { User } from "@/lib/auth/tokens";
import { pickLocale } from "@/lib/i18n/locale";
import { isValidDate } from "@/lib/calendar/dates";
import { addMemberSchema, addPersonSchema, birthdaySchema, familyNameSchema, personSchema, role as roleSchema } from "@/lib/schemas/auth";
import { createChannel, deleteChannel, listChannels, updateChannel } from "@/lib/notifications/channels";
import { channelInputSchema } from "@/lib/notifications/schema";
import { sendTestNotification } from "@/lib/notifications";
import { EVENT_HAS_CHANNELS, getPrefs, NOTIFY_EVENTS, setPref } from "@/lib/notifications/prefs";
import { familyDashboard } from "./dashboard";
import { homeAddressSchema, setHomeAddress } from "./home";
import { createInvite, listInvites, revokeInvite } from "./invites";
import { createFamily, deleteFamily, type FamilyDto } from "./manage";
import { addMember, listMembers, removeMember, setMemberBirthday, setRole } from "./members";
import { addPerson, listPeople, removePerson, updatePerson } from "./people";
import type { Role } from "./roles";
import { SEARCH_DEFAULT_LIMIT, SEARCH_MAX_LIMIT, searchFamily } from "./search";

type Handler = (ctx: Ctx, args: string[]) => Promise<Response>;

/** Routes /overview, /search and /household/...; null for anything else. */
export function handleFamilyApp(ctx: Ctx): Promise<Response> | null {
  const { rest, method } = ctx;
  if (rest[0] === "overview" && rest.length === 1) {
    return method === "GET" ? overview(ctx) : notAllowed();
  }
  if (rest[0] === "search" && rest.length === 1) {
    return method === "GET" ? search(ctx) : notAllowed();
  }
  if (rest[0] !== "household") return null;
  const sub = rest.slice(1);
  const routes: [string[], Record<string, Handler>][] = [
    [[], { GET: household, DELETE: removeFamily }],
    [["members"], { POST: addMemberRoute }],
    [["members", "*"], { PATCH: updateMember, DELETE: removeMemberRoute }],
    [["people"], { POST: addPersonRoute }],
    [["people", "*"], { PATCH: updatePersonRoute, DELETE: removePersonRoute }],
    [["invites"], { POST: createInviteRoute }],
    [["invites", "*"], { DELETE: revokeInviteRoute }],
    [["home"], { PUT: setHome }],
    [["notifications", "channels"], { POST: createChannelRoute }],
    [["notifications", "channels", "*"], { PATCH: updateChannelRoute, DELETE: deleteChannelRoute }],
    [["notifications", "channels", "*", "test"], { POST: testChannel }],
    [["notifications", "events", "*"], { PUT: setEvent }],
  ];
  for (const [pattern, methods] of routes) {
    if (pattern.length !== sub.length || !pattern.every((p, i) => p === "*" || p === sub[i])) continue;
    const fn = methods[method];
    const args = sub.filter((_, i) => pattern[i] === "*");
    return fn ? fn(ctx, args) : notAllowed();
  }
  return Promise.reject(new HttpError(404, "Not found"));
}

const notAllowed = () => Promise.reject(new HttpError(405, "Method not allowed"));

/** The signed-in member and the family id (404 for non-members, 403 for viewers with "edit"). */
async function member(ctx: Ctx, need: "view" | "edit" = "view"): Promise<{ user: User; familyId: string; role: Role }> {
  const { family, access } = await ctx.load(need);
  return { user: ctx.requireUser(), familyId: family.id, role: access === "edit" ? "editor" : "viewer" };
}

/** The public address of the web app (invite links). */
function appUrl(ctx: Ctx): string {
  return ctx.publicBase.replace(/\/api\/v1$/, "");
}

const inviteUrl = (ctx: Ctx, code: string) => `${appUrl(ctx)}/invite/${code}`;

// ---- Overview ----

async function overview(ctx: Ctx): Promise<Response> {
  const { familyId } = await member(ctx);
  const asked = ctx.url.searchParams.get("today");
  const today = asked && isValidDate(asked) ? asked : ctx.now.toISOString().slice(0, 10);
  return json(await familyDashboard(ctx.db, familyId, today));
}

// ---- Search ----

async function search(ctx: Ctx): Promise<Response> {
  const { user, familyId } = await member(ctx);
  const params = ctx.url.searchParams;
  const asked = params.get("today");
  const today = asked && isValidDate(asked) ? asked : ctx.now.toISOString().slice(0, 10);
  const limit = Math.min(SEARCH_MAX_LIMIT, Math.max(1, Number(params.get("limit")) || SEARCH_DEFAULT_LIMIT));
  return json(searchFamily(ctx.db, familyId, user.id, params.get("q") ?? "", { today, limit }));
}

// ---- Household ----

export interface HouseholdDto {
  name: string;
  role: Role;
  selfId: string;
  members: ReturnType<typeof listMembers>;
  people: { id: string; name: string; birthday: string | null }[];
  /** Open invites (editors only; [] for viewers). */
  invites: { id: string; url: string; role: string; personId: string | null; expiresAt: Date }[];
  home: { address: string | null; lat: number | null; lng: number | null };
  channels: ReturnType<typeof listChannels>;
  /** The notification events, with whether they pick their channels here. */
  events: { event: string; enabled: boolean; channelIds: string[] | null; hasChannels: boolean }[];
}

function householdOf(ctx: Ctx, user: User, familyId: string, role: Role): HouseholdDto {
  const { db, now } = ctx;
  const actor = { id: user.id };
  const row = db.select().from(families).where(eq(families.id, familyId)).get()!;
  return {
    name: row.name,
    role,
    selfId: user.id,
    members: listMembers(db, actor, familyId),
    people: listPeople(db, actor, familyId).map((p) => ({ id: p.id, name: p.name, birthday: p.birthday })),
    invites:
      role === "editor"
        ? listInvites(db, actor, familyId, now).map((i) => ({
            id: i.id,
            url: inviteUrl(ctx, i.code),
            role: i.role,
            personId: i.personId,
            expiresAt: i.expiresAt,
          }))
        : [],
    home: { address: row.homeAddress, lat: row.homeLat, lng: row.homeLng },
    channels: listChannels(db, actor, familyId),
    events: getPrefs(db, familyId).map((p) => ({ ...p, hasChannels: EVENT_HAS_CHANNELS[p.event] })),
  };
}

const household: Handler = async (ctx) => {
  const { user, familyId, role } = await member(ctx);
  return json(householdOf(ctx, user, familyId, role));
};

const removeFamily: Handler = async (ctx) => {
  const { user, familyId } = await member(ctx, "edit");
  deleteFamily(ctx.db, { id: user.id }, familyId);
  return json({ ok: true });
};

// ---- Members ----

const addMemberRoute: Handler = async (ctx) => {
  const { user, familyId } = await member(ctx, "edit");
  const input = addMemberSchema.parse(await readBody(ctx.req));
  return json(addMember(ctx.db, { id: user.id }, familyId, input, ctx.now), 201);
};

const memberPatchSchema = z.object({ role: roleSchema.optional(), birthday: birthdaySchema.optional() });

/** A role and / or a birthday (members set their own birthday, editors anyone's). */
const updateMember: Handler = async (ctx, [userId]) => {
  const { user, familyId } = await member(ctx);
  const raw = await readBody(ctx.req);
  const input = memberPatchSchema.parse(raw);
  const actor = { id: user.id };
  if (input.role !== undefined) setRole(ctx.db, actor, familyId, userId, input.role);
  if ("birthday" in raw) setMemberBirthday(ctx.db, actor, familyId, userId, input.birthday ?? null, ctx.now);
  const updated = listMembers(ctx.db, actor, familyId).find((m) => m.userId === userId);
  if (!updated) throw new HttpError(404, "Member not found.");
  return json(updated);
};

/** Everyone may remove themselves (leave), editors anyone. */
const removeMemberRoute: Handler = async (ctx, [userId]) => {
  const { user, familyId } = await member(ctx);
  removeMember(ctx.db, { id: user.id }, familyId, userId);
  return json({ ok: true });
};

// ---- People without an account ----

const addPersonRoute: Handler = async (ctx) => {
  const { user, familyId } = await member(ctx, "edit");
  const input = addPersonSchema.parse(await readBody(ctx.req));
  const res = addPerson(ctx.db, { id: user.id }, familyId, input, ctx.now);
  return json(
    {
      person: { id: res.person.id, name: res.person.name, birthday: res.person.birthday },
      invite: res.invite ? { ...res.invite, url: inviteUrl(ctx, res.invite.code) } : null,
    },
    201,
  );
};

const updatePersonRoute: Handler = async (ctx, [personId]) => {
  const { user, familyId } = await member(ctx, "edit");
  const input = personSchema.parse(await readBody(ctx.req));
  updatePerson(ctx.db, { id: user.id }, familyId, personId, input, ctx.now);
  return json({ id: personId, name: input.name, birthday: input.birthday });
};

const removePersonRoute: Handler = async (ctx, [personId]) => {
  const { user, familyId } = await member(ctx, "edit");
  removePerson(ctx.db, { id: user.id }, familyId, personId);
  return json({ ok: true });
};

// ---- Invites ----

const inviteSchema = z.object({ role: roleSchema, personId: z.string().min(1).nullish() });

const createInviteRoute: Handler = async (ctx) => {
  const { user, familyId } = await member(ctx, "edit");
  const input = inviteSchema.parse(await readBody(ctx.req));
  const invite = createInvite(ctx.db, { id: user.id }, familyId, input.role, ctx.now, input.personId ?? undefined);
  return json({ ...invite, url: inviteUrl(ctx, invite.code) }, 201);
};

const revokeInviteRoute: Handler = async (ctx, [inviteId]) => {
  const { user, familyId } = await member(ctx, "edit");
  revokeInvite(ctx.db, { id: user.id }, familyId, inviteId);
  return json({ ok: true });
};

// ---- Home address ----

const setHome: Handler = async (ctx) => {
  const { user, familyId } = await member(ctx, "edit");
  setHomeAddress(ctx.db, { id: user.id }, familyId, homeAddressSchema.parse(await readBody(ctx.req)), ctx.now);
  const row = ctx.db.select().from(families).where(eq(families.id, familyId)).get()!;
  return json({ address: row.homeAddress, lat: row.homeLat, lng: row.homeLng });
};

// ---- Notifications ----

const createChannelRoute: Handler = async (ctx) => {
  const { user, familyId } = await member(ctx, "edit");
  const input = channelInputSchema.parse(await readBody(ctx.req));
  const { id } = createChannel(ctx.db, { id: user.id }, familyId, input, ctx.now);
  return json(channelById(ctx, user, familyId, id), 201);
};

const updateChannelRoute: Handler = async (ctx, [channelId]) => {
  const { user, familyId } = await member(ctx, "edit");
  const input = channelInputSchema.parse(await readBody(ctx.req));
  updateChannel(ctx.db, { id: user.id }, familyId, channelId, input);
  return json(channelById(ctx, user, familyId, channelId));
};

function channelById(ctx: Ctx, user: User, familyId: string, id: string) {
  return listChannels(ctx.db, { id: user.id }, familyId).find((c) => c.id === id)!;
}

const deleteChannelRoute: Handler = async (ctx, [channelId]) => {
  const { user, familyId } = await member(ctx, "edit");
  deleteChannel(ctx.db, { id: user.id }, familyId, channelId);
  return json({ ok: true });
};

/** Sends a test message right away (one short request to the provider; 502 when it fails). */
const testChannel: Handler = async (ctx, [channelId]) => {
  const { user, familyId } = await member(ctx, "edit");
  await sendTestNotification(ctx.db, { id: user.id }, familyId, channelId);
  return json({ ok: true });
};

const setEvent: Handler = async (ctx, [event]) => {
  const { user, familyId } = await member(ctx, "edit");
  if (!(NOTIFY_EVENTS as readonly string[]).includes(event)) throw new HttpError(404, "Not found");
  const body = await readBody(ctx.req);
  const pref = setPref(ctx.db, { id: user.id }, familyId, { ...body, event }, ctx.now);
  return json({ ...pref, hasChannels: EVENT_HAS_CHANNELS[pref.event] });
};

// ---- Creating a family (POST /api/v1/families) ----

/** Creates a family with `user` as its editor, its presets named in the user's language (else
 *  the request's Accept-Language), like createFamilyAction. */
export function createFamilyForUser(
  db: Db,
  user: Pick<User, "id" | "preferredLanguage">,
  body: unknown,
  acceptLanguage: string | null,
  now: Date,
): FamilyDto {
  const { name } = familyNameSchema.parse(body);
  const lang = pickLocale([user.preferredLanguage, acceptLanguage?.split(",")[0]]);
  const family = createFamily(db, { name, editorId: user.id, lang }, now);
  return { id: family.id, name: family.name, role: "editor", memberCount: 1 };
}
