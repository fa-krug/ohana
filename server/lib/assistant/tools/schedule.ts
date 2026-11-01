// The assistant's look at the week ahead (phase 11): check_schedule reads the issues the rules
// in lib/digest/checks.ts find (clashes, tight transfers, packed days, …). It doesn't make any
// up; it only reads.

import { HttpError } from "@/lib/api/http";
import { addDays, diffDays, isValidDate } from "@/lib/calendar/dates";
import { scheduleIssues } from "@/lib/digest/digest";
import { fitting, type Tool } from "./common";

/** Days check_schedule looks at by default, and at most. */
export const SCHEDULE_DEFAULT_DAYS = 14;
export const SCHEDULE_MAX_DAYS = 60;

export const scheduleTools: Record<string, Tool> = {
  check_schedule: {
    spec: {
      name: "check_schedule",
      description:
        "Checks the family's calendar events for problems: one person in two places at once, too little time to get from one place to the next, packed days, long drives, short nights, events while the family is away, children needing more drivers than there are adults free, someone away on a birthday, overlapping events nobody is assigned to. Default: the next 14 days (max. 60). Issues marked dismissed were marked as fine by the family.",
      parameters: {
        type: "object",
        properties: {
          from: { type: "string", description: "YYYY-MM-DD (default: today)" },
          to: { type: "string", description: "YYYY-MM-DD (default: 13 days after from)" },
        },
      },
    },
    async run(args, { db, familyId, today, now }) {
      const day = today ?? (now?.() ?? new Date()).toISOString().slice(0, 10);
      const from = args.from === undefined || args.from === null || args.from === "" ? day : args.from;
      if (!isValidDate(from)) throw new HttpError(400, "from must be YYYY-MM-DD");
      const to = args.to === undefined || args.to === null || args.to === "" ? addDays(from, SCHEDULE_DEFAULT_DAYS - 1) : args.to;
      if (!isValidDate(to)) throw new HttpError(400, "to must be YYYY-MM-DD");
      if (from > to) throw new HttpError(400, "from must not be after to");
      if (diffDays(from, to) >= SCHEDULE_MAX_DAYS) throw new HttpError(400, `The range is too long (max. ${SCHEDULE_MAX_DAYS} days)`);
      const issues = scheduleIssues(db, familyId, from, to);
      const shown = fitting({ from, to }, issues);
      return {
        result: { from, to, issues: shown, ...(shown.length < issues.length ? { more: issues.length - shown.length } : {}) },
        summary: `${issues.length} issues`,
      };
    },
  },
};
