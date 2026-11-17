// The assistant's tools for check-ups and vaccinations (phase 13): where each member stands, and
// recording one ("Mia had her U7 today", "Papa's tetanus shot was in May 2019"). Like the REST
// routes, a viewer's chat sees only their own. Undo goes through /health/records: a new record is
// deleted, one it replaced POSTed back with its id; a removed one is POSTed back.

import { HttpError } from "@/lib/api/http";
import { getRole } from "@/lib/families/roles";
import {
  type HealthMember,
  type Row,
  addRecords,
  deleteRecord,
  healthMembers,
  listHealth,
  recordInput,
  recordOut,
} from "@/lib/health/health";
import { SCHEDULE_AS_OF } from "@/lib/health/schedule";
import type { ItemState } from "@/lib/health/status";
import { fitting, type Tool, type ToolContext, type UndoStep } from "./common";

const PHRASES = {
  en: {
    recorded: (n: number, name: string) => (n === 1 ? `Recorded a check-up / vaccination for ${name}` : `Recorded ${n} check-ups / vaccinations for ${name}`),
    removed: (name: string) => `Removed a check-up / vaccination record of ${name}`,
  },
  de: {
    recorded: (n: number, name: string) => (n === 1 ? `Untersuchung / Impfung für ${name} eingetragen` : `${n} Untersuchungen / Impfungen für ${name} eingetragen`),
    removed: (name: string) => `Eintrag einer Untersuchung / Impfung von ${name} entfernt`,
  },
};

const today = (ctx: ToolContext) => ctx.today ?? (ctx.now?.() ?? new Date()).toISOString().slice(0, 10);
const enc = encodeURIComponent;

/** Null for an editor (everyone), else the user's own id. */
function viewerOf(ctx: ToolContext): string | null {
  if (!ctx.userId) return null;
  return getRole(ctx.db, ctx.familyId, ctx.userId) === "editor" ? null : ctx.userId;
}

/** A member by name (case ignored) or id, among those the user may see. */
function memberOf(ctx: ToolContext, v: unknown): HealthMember {
  const members = healthMembers(ctx.db, ctx.familyId, viewerOf(ctx));
  const s = String(v ?? "").trim();
  const m = members.find((x) => x.id === s) ?? members.find((x) => x.name.toLocaleLowerCase() === s.toLocaleLowerCase());
  if (!m) throw new HttpError(400, `“${s}” isn't one of: ${members.map((x) => x.name).join(", ")}`);
  return m;
}

function compactItem(i: ItemState) {
  return {
    code: i.code,
    title: i.title,
    ...(i.vaccines.length ? { vaccines: i.vaccines } : {}),
    status: i.status,
    from: i.from,
    until: i.until,
    ...(i.notAlwaysPaid ? { notAlwaysPaid: true } : {}),
    ...(i.records.length ? { records: i.records } : {}),
  };
}

const restore = (memberId: string, rows: Row[]): UndoStep => ({
  method: "POST",
  path: "/health/records",
  body: { memberId, records: rows.map((r) => ({ id: r.id, code: r.code, day: r.day, status: r.status, note: r.note })) },
});

export const healthTools: Record<string, Tool> = {
  get_health: {
    spec: {
      name: "get_health",
      description:
        "Check-ups (German U1–U11, J1, J2) and vaccinations (STIKO calendar: children's by visit, adults' tetanus every 10 years, flu / COVID-19 each autumn from 60 …) of the family's members, worked out from their birthdays: each item's code, status (done, skipped, due, upcoming, past = a child's window closed without a record, unknown = never recorded), window (from, until) and records. A member without a birthday has no items. The booklets (Impfpass, U-Heft) are what counts; this only reminds.",
      parameters: {
        type: "object",
        properties: { member: { type: "string", description: "A member's name or id (none: everyone)" } },
      },
    },
    async run(args, ctx) {
      const day = today(ctx);
      const only = args.member ? memberOf(ctx, args.member).id : null;
      const members = listHealth(ctx.db, ctx.familyId, viewerOf(ctx), day, ctx.lang)
        .filter((m) => !only || m.id === only)
        .map((m) => ({
          id: m.id,
          name: m.name,
          birthday: m.birthday,
          next: m.next ? { code: m.next.code, title: m.next.title, status: m.next.status, from: m.next.from, until: m.next.until } : null,
          items: m.items.map(compactItem),
        }));
      const shown = fitting({ asOf: SCHEDULE_AS_OF }, members);
      return {
        result: { asOf: SCHEDULE_AS_OF, members: shown, ...(shown.length < members.length ? { more: members.length - shown.length } : {}) },
        summary: `${members.length} members`,
      };
    },
  },

  record_health: {
    write: true,
    spec: {
      name: "record_health",
      description:
        "Records check-ups or vaccinations a member had (or skipped), by the codes of get_health. A check-up or a child's vaccination visit is recorded once (a new record replaces the old one); tetanus, flu and COVID-19 once each time. day: when (null: done, date unknown; never in the future).",
      parameters: {
        type: "object",
        properties: {
          member: { type: "string", description: "The member's name or id" },
          records: {
            type: "array",
            items: {
              type: "object",
              properties: {
                code: { type: "string" },
                day: { type: ["string", "null"], description: "YYYY-MM-DD" },
                status: { type: "string", enum: ["done", "skipped"] },
                note: { type: "string", description: "e.g. the vaccine's name (max. 200 characters)" },
              },
              required: ["code"],
            },
          },
        },
        required: ["member", "records"],
      },
    },
    async run(args, ctx) {
      const member = memberOf(ctx, args.member);
      if (!Array.isArray(args.records) || !args.records.length) throw new HttpError(400, "records must be a non-empty list");
      const day = today(ctx);
      const inputs = args.records.map((r) => recordInput(r, member, day));
      const { records, replaced } = addRecords(ctx.db, ctx.familyId, member, inputs, {
        createdById: ctx.userId ?? null,
        now: ctx.now?.() ?? new Date(),
      });
      const undo: UndoStep[] = records.map((r) => ({ method: "DELETE", path: `/health/records/${enc(r.id)}` }));
      if (replaced.length) undo.push(restore(member.id, replaced));
      return {
        result: { records: records.map(recordOut), ...(replaced.length ? { replaced: replaced.map(recordOut) } : {}) },
        summary: `${records.length} for ${member.name}`,
        change: { kind: "health", summary: PHRASES[ctx.lang].recorded(records.length, member.name), undo },
      };
    },
  },

  remove_health_record: {
    write: true,
    spec: {
      name: "remove_health_record",
      description: "Removes a check-up or vaccination record (by its id from get_health).",
      parameters: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    },
    async run(args, ctx) {
      const row = deleteRecord(ctx.db, ctx.familyId, String(args.id ?? ""), viewerOf(ctx));
      const memberId = (row.memberUserId ?? row.memberPersonId)!;
      const name = healthMembers(ctx.db, ctx.familyId, null).find((m) => m.id === memberId)?.name ?? "";
      return {
        result: { deleted: row.id },
        summary: row.code,
        change: { kind: "health", summary: PHRASES[ctx.lang].removed(name), undo: [restore(memberId, [row])] },
      };
    },
  },
};
