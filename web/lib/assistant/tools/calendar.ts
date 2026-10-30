// The assistant's calendar tools: read, count and change entries, day notes and entry types
// (with the same validation as the REST API). Every change comes with undo steps: requests
// against the family's own API that put things back.

import { cleanName, HttpError, slug } from "@/lib/api/http";
import { dateRange, diffDays, isWeekend } from "@/lib/calendar/dates";
import type { CalendarStore as Store, TypeRow } from "@/lib/calendar/store";
import {
  applyEntryOps,
  applyNoteOps,
  cleanColor,
  cleanRole,
  MAX_TYPES,
  parseEntryOps,
  parseNoteOps,
  publicType,
  resolveType,
  uniqueId,
} from "@/lib/calendar/vacation";
import { analyzeCalendar, CALENDAR_DIMENSIONS } from "../analytics";
import {
  choices,
  CONFIRM_DAYS,
  fitting,
  MAX_ANALYZE_DAYS,
  MAX_RANGE_DAYS,
  needConfirm,
  opsSchema,
  PHRASES,
  range,
  type Tool,
  yearOf,
} from "./common";

/** Weekdays with a "needs cover" entry and nothing that covers it. */
function gaps(types: TypeRow[], entries: Map<string, string[]>): string[] {
  const role = new Map(types.map((t) => [`${t.year}|${t.id}`, t.role]));
  const out: string[] = [];
  for (const [day, ids] of entries) {
    if (isWeekend(day)) continue;
    const roles = ids.map((id) => role.get(`${yearOf(day)}|${id}`));
    if (roles.includes("needs_cover") && !roles.some((r) => r === "covers" || r === "day_off")) {
      out.push(day);
    }
  }
  return out.sort();
}

async function entriesOn(store: Store, familyId: string, days: string[]) {
  const map = new Map<string, string[]>(days.map((d) => [d, []]));
  if (!days.length) return map;
  const sorted = [...days].sort();
  for (const r of await store.listEntries(familyId, sorted[0], sorted.at(-1))) {
    map.get(r.day)?.push(r.type_id);
  }
  return map;
}


const daysProps = {
  dates: { type: "array", items: { type: "string" }, description: "Days as YYYY-MM-DD." },
  from: { type: "string", description: "First day of an inclusive range (YYYY-MM-DD)." },
  to: { type: "string", description: "Last day of the range (YYYY-MM-DD)." },
  skipWeekends: { type: "boolean", description: "Leave out Saturdays and Sundays." },
};


export const calendarTools: Record<string, Tool> = {
  get_calendar: {
    spec: {
      name: "get_calendar",
      description:
        "Reads the vacation calendar between two days: the entry types of those years, the entries per day (type ids), day notes, and gaps (weekdays that need cover but have none).",
      parameters: {
        type: "object",
        properties: {
          from: { type: "string", description: "YYYY-MM-DD" },
          to: { type: "string", description: "YYYY-MM-DD, at most about a year after from" },
        },
        required: ["from", "to"],
      },
    },
    async run(args, { calendar: store, familyId }) {
      const { from, to } = range(args);
      if (dateRange(from, to).length > MAX_RANGE_DAYS) {
        throw new HttpError(400, "Read at most about a year at a time");
      }
      const [types, rows, notes] = await Promise.all([
        store.listTypes(familyId),
        store.listEntries(familyId, from, to),
        store.listNotes(familyId, from, to),
      ]);
      const inRange = types.filter((t) => t.year >= yearOf(from) && t.year <= yearOf(to));
      const entries = new Map<string, string[]>();
      for (const r of rows) entries.set(r.day, [...(entries.get(r.day) ?? []), r.type_id]);
      return {
        result: {
          types: inRange.map(publicType),
          entries: Object.fromEntries(entries),
          notes: Object.fromEntries(
            notes.map((n) => [n.day, { icon: n.icon, comment: n.comment }]),
          ),
          gaps: gaps(inRange, entries),
        },
        summary: `${from} – ${to}`,
      };
    },
  },

  analyze_calendar: {
    spec: {
      name: "analyze_calendar",
      description:
        'Counts calendar days instead of you counting them in get_calendar: days per entry type (a day counts once for each of its types), year, month and/or weekday between two days, e.g. vacation days per parent this year. groupBy: up to 2 of type, year, month, weekday (default type; without type a day counts once whatever it holds). types: only these (ids or names). weekdaysOnly: leave out Saturdays and Sundays. skipDaysOff: leave out entries on days that also have a "day off" entry (vacation on a public holiday costs no vacation day).',
      parameters: {
        type: "object",
        properties: {
          from: { type: "string", description: "YYYY-MM-DD" },
          to: { type: "string", description: "YYYY-MM-DD, at most about ten years after from" },
          groupBy: { type: "array", items: { type: "string", enum: [...CALENDAR_DIMENSIONS] } },
          types: { type: "array", items: { type: "string" } },
          weekdaysOnly: { type: "boolean" },
          skipDaysOff: { type: "boolean" },
        },
        required: ["from", "to"],
      },
    },
    async run(args, { calendar: store, familyId }) {
      const { from, to } = range(args);
      if (diffDays(from, to) >= MAX_ANALYZE_DAYS) {
        throw new HttpError(400, "Analyze at most about ten years at a time");
      }
      const asked = choices(args.groupBy, CALENDAR_DIMENSIONS, "groupBy", 2);
      const groupBy = asked?.length ? asked : ["type" as const];
      const [types, entries] = await Promise.all([
        store.listTypes(familyId),
        store.listEntries(familyId, from, to),
      ]);
      let only: Set<string> | undefined;
      if (args.types !== undefined) {
        const refs = Array.isArray(args.types) ? args.types : [args.types];
        only = new Set();
        for (const ref of refs) {
          const name = String(ref).trim().toLowerCase();
          const ids = types.filter((t) => t.id === ref || t.name.toLowerCase() === name);
          if (!ids.length) throw new HttpError(404, `Unknown entry type "${ref}"`);
          for (const t of ids) only.add(t.id);
        }
      }
      const res = analyzeCalendar({
        types,
        entries,
        from,
        to,
        only,
        groupBy,
        weekdaysOnly: args.weekdaysOnly === true,
        skipDaysOff: args.skipDaysOff === true,
      });
      const head = { from, to, groupBy, days: res.days };
      const groups = fitting(head, res.groups);
      return {
        result: {
          ...head,
          groups,
          ...(groups.length < res.groups.length ? { more: res.groups.length - groups.length } : {}),
        },
        summary: `${res.days} days`,
      };
    },
  },

  change_entries: {
    write: true,
    spec: {
      name: "change_entries",
      description:
        'Changes calendar entries. Each op: {"action": "add" | "remove" | "set" | "clear", "type" or "types" (id or name, resolved in each day\'s year), and the days}. "add" keeps other entries, "set" replaces them, "clear" removes all.',
      parameters: opsSchema({
        type: "object",
        properties: {
          action: { type: "string", enum: ["add", "remove", "set", "clear"] },
          type: { type: "string" },
          types: { type: "array", items: { type: "string" } },
          ...daysProps,
        },
        required: ["action"],
      }),
    },
    async run(args, { calendar: store, familyId, lang }) {
      const types = await store.listTypes(familyId);
      const { ops, total } = parseEntryOps({ ops: args.ops }, types);
      const days = [...new Set(ops.flatMap((o) => o.days))].sort();
      if (days.length > CONFIRM_DAYS) needConfirm(args, `This changes ${days.length} days.`);
      const before = await entriesOn(store, familyId, days);
      await applyEntryOps(store, familyId, ops);
      const after = await entriesOn(store, familyId, days);
      const changed = days.filter((d) =>
        [...before.get(d)!].sort().join() !== [...after.get(d)!].sort().join()
      );
      // Undo: put each changed day back to its old types, grouped by the same set of types.
      const groups = new Map<string, string[]>();
      for (const d of changed) {
        const key = [...before.get(d)!].sort().join(",");
        groups.set(key, [...(groups.get(key) ?? []), d]);
      }
      const undoOps = [...groups].map(([key, dates]) =>
        key ? { action: "set", types: key.split(","), dates } : { action: "clear", dates }
      );
      return {
        result: { ok: true, days: total, changed: changed.length },
        summary: `${changed.length} days changed`,
        change: changed.length
          ? {
            kind: "entries",
            summary: PHRASES[lang].days(changed.length),
            undo: [{ method: "POST", path: "/entries", body: { ops: undoOps } }],
          }
          : undefined,
      };
    },
  },

  set_notes: {
    write: true,
    spec: {
      name: "set_notes",
      description:
        'Sets or clears day notes (one per day: an emoji icon and/or a comment, e.g. 🎄 "Christmas"). Each op: {"action": "set" | "clear", "icon", "comment", and the days}.',
      parameters: opsSchema({
        type: "object",
        properties: {
          action: { type: "string", enum: ["set", "clear"] },
          icon: { type: "string", description: "One emoji" },
          comment: { type: "string", description: "Up to 500 characters" },
          ...daysProps,
        },
        required: ["action"],
      }),
    },
    async run(args, { calendar: store, familyId, lang }) {
      const { ops, total } = parseNoteOps({ ops: args.ops });
      const days = [...new Set(ops.flatMap((o) => o.days))].sort();
      if (days.length > CONFIRM_DAYS) {
        needConfirm(args, `This changes the notes of ${days.length} days.`);
      }
      const old = new Map(
        (await store.listNotes(familyId, days[0], days.at(-1))).map((n) => [n.day, n]),
      );
      await applyNoteOps(store, familyId, ops);
      const undoOps = days.map((d) => {
        const n = old.get(d);
        return n
          ? { action: "set", dates: [d], icon: n.icon, comment: n.comment }
          : { action: "clear", dates: [d] };
      });
      return {
        result: { ok: true, days: total },
        summary: `${total} notes changed`,
        change: {
          kind: "notes",
          summary: PHRASES[lang].notes(total),
          undo: [{ method: "POST", path: "/notes", body: { ops: undoOps } }],
        },
      };
    },
  },

  manage_entry_types: {
    write: true,
    spec: {
      name: "manage_entry_types",
      description:
        'Adds, changes, deletes or copies entry types. Every year has its own types. "add": name, color (#rrggbb), role. "update": type (id or name) and any of name, color, role. "delete": type (also deletes its entries in that year; needs confirmed). "copy_year": from and to (years).',
      parameters: {
        type: "object",
        properties: {
          action: { type: "string", enum: ["add", "update", "delete", "copy_year"] },
          year: { type: "integer" },
          type: { type: "string" },
          name: { type: "string" },
          color: { type: "string" },
          role: { type: "string", enum: ["none", "needs_cover", "covers", "day_off"] },
          from: { type: "integer" },
          to: { type: "integer" },
          confirmed: { type: "boolean" },
        },
        required: ["action"],
      },
    },
    async run(args, { calendar: store, familyId, lang }) {
      const all = await store.listTypes(familyId);
      const year = Number(args.year ?? new Date().getUTCFullYear());
      if (!Number.isInteger(year) || year < 1900 || year > 2200) {
        throw new HttpError(400, "Invalid year");
      }
      const types = all.filter((t) => t.year === year);
      const path = (id: string) => `/types/${encodeURIComponent(id)}?year=${year}`;
      switch (args.action) {
        case "add": {
          if (types.length >= MAX_TYPES) throw new HttpError(400, "Too many entry types");
          const name = cleanName(args.name);
          const type: TypeRow = {
            family_id: familyId,
            year,
            id: uniqueId(slug(name), new Set(types.map((t) => t.id))),
            name,
            color: cleanColor(args.color ?? "#64748b"),
            role: cleanRole(args.role),
            position: types.reduce((m, t) => Math.max(m, t.position + 1), 0),
          };
          await store.upsertTypes([type]);
          return {
            result: publicType(type),
            summary: `Added “${name}” (${year})`,
            change: {
              kind: "types",
              summary: PHRASES[lang].typeAdded(name, year),
              undo: [{ method: "DELETE", path: path(type.id) }],
            },
          };
        }
        case "update": {
          const type = resolveType(all, args.type, year);
          const next = { ...type };
          if (args.name !== undefined) next.name = cleanName(args.name);
          if (args.color !== undefined) next.color = cleanColor(args.color);
          if (args.role !== undefined) next.role = cleanRole(args.role);
          await store.upsertTypes([next]);
          return {
            result: publicType(next),
            summary: `Changed “${next.name}” (${year})`,
            change: {
              kind: "types",
              summary: PHRASES[lang].typeChanged(type.name, year),
              undo: [{
                method: "PATCH",
                path: path(type.id),
                body: { name: type.name, color: type.color, role: type.role },
              }],
            },
          };
        }
        case "delete": {
          const type = resolveType(all, args.type, year);
          needConfirm(
            args,
            `Deleting “${type.name}” also deletes its entries in ${year} and can't be undone.`,
          );
          await store.deleteType(familyId, year, type.id);
          return {
            result: { deleted: type.id, year },
            summary: `Deleted “${type.name}” (${year})`,
          };
        }
        case "copy_year": {
          const from = Number(args.from), to = Number(args.to);
          const source = all.filter((t) => t.year === from);
          if (!source.length) throw new HttpError(404, `${from} has no entry types`);
          const target = all.filter((t) => t.year === to);
          const taken = new Set(target.map((t) => t.id));
          let position = target.reduce((m, t) => Math.max(m, t.position + 1), 0);
          const copies = source.filter((t) => !taken.has(t.id))
            .slice(0, Math.max(0, MAX_TYPES - target.length))
            .map((t) => ({ ...t, year: to, position: position++ }));
          await store.upsertTypes(copies);
          return {
            result: [...target, ...copies].map(publicType),
            summary: `Copied ${copies.length} types to ${to}`,
            change: copies.length
              ? {
                kind: "types",
                summary: PHRASES[lang].typesCopied(copies.length, from, to),
                undo: copies.map((t) => ({
                  method: "DELETE" as const,
                  path: `/types/${encodeURIComponent(t.id)}?year=${to}`,
                })),
              }
              : undefined,
          };
        }
      }
      throw new HttpError(400, "action must be add, update, delete or copy_year");
    },
  },

};
