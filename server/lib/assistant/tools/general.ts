// Tools of no module: exact calculations, and questions to the user.

import { HttpError, objectOf } from "@/lib/api/http";
import { CalcError, calculate, MAX_EXPRESSIONS } from "../calc";
import { MAX_OPTION, MAX_OPTIONS, MAX_QUESTION, type Tool } from "./common";

export const generalTools: Record<string, Tool> = {
  calculate: {
    spec: {
      name: "calculate",
      description:
        'Calculates exactly; use it for any arithmetic instead of working it out yourself. Numbers, lists [1, 2, 3], + - * / % ^ (element by element on lists), parentheses, "name = …" to reuse a result in later expressions, and functions: abs sqrt exp ln log(x, base=10) round(x, digits) floor ceil pow; sum count min max avg median stddev variance percentile(list, p 0–100) product; sort cumsum diff growth (relative change per step) seq(from, to, step); slope(y, x?) intercept(y, x?) correl(x, y) forecast(y, k) (the linear trend k steps after the last value); money, like spreadsheets (rate per period, money paid out negative): pmt(rate, nper, pv, fv?, type?) fv(rate, nper, pmt, pv?, type?) pv(rate, nper, pmt, fv?, type?) nper(rate, pmt, pv, fv?) npv(rate, flows) irr(flows) cagr(start, end, years). Constants pi, e. Each expression gets its value or an error. Put all the math of an answer into one call: later expressions can use earlier names.',
      parameters: {
        type: "object",
        properties: {
          expressions: {
            type: "array",
            items: { type: "string" },
            description: 'Evaluated in order, e.g. ["rate = 0.035 / 12", "pmt(rate, 240, 300000)"]',
          },
          vars: {
            type: "object",
            description:
              'Named numbers or lists of numbers, e.g. {"spent": [412.5, 380, 455.2]} (from other tools\' results)',
          },
        },
        required: ["expressions"],
      },
    },
    run(args) {
      const raw = args.expressions ?? args.expression;
      const expressions = Array.isArray(raw) ? raw : [raw];
      if (!expressions.length || expressions.some((e) => typeof e !== "string")) {
        throw new HttpError(400, "expressions must be a list of strings");
      }
      if (expressions.length > MAX_EXPRESSIONS) {
        throw new HttpError(400, `At most ${MAX_EXPRESSIONS} expressions at a time`);
      }
      let results;
      try {
        results = calculate(expressions as string[], objectOf(args.vars ?? {}, "vars"));
      } catch (err) {
        if (err instanceof CalcError) throw new HttpError(400, err.message);
        throw err;
      }
      const last = results.at(-1)!;
      return Promise.resolve({
        result: { results },
        summary: results.length === 1 && last.value !== undefined && !Array.isArray(last.value)
          ? `${last.expression.slice(0, 60)} = ${last.value}`
          : `${results.length} ${results.length === 1 ? "result" : "results"}`,
      });
    },
  },

  ask_user: {
    spec: {
      name: "ask_user",
      description:
        'Asks the user a question with answers to pick from. Use it whenever you need their decision or a detail only they know, instead of guessing or asking in plain text: which of several matches, which option they prefer, a missing detail, their OK for a bigger change, what to do next. Give 2 to 8 short, distinct options; multiple: true lets them pick several. They can always write their own answer instead, so don\'t add an "Other" option. The answer comes back as this tool\'s result: {"selected": [...]} and/or {"ownAnswer": "..."}, or {"skipped": true} when they wrote a new message instead. Ask one question at a time; call no other tools after it in the same step.',
      parameters: {
        type: "object",
        properties: {
          question: { type: "string" },
          options: { type: "array", items: { type: "string" } },
          multiple: { type: "boolean", description: "Several answers can be picked" },
        },
        required: ["question", "options"],
      },
    },
    run(args) {
      const question = String(args.question ?? "").trim();
      if (!question) throw new HttpError(400, "question is required");
      if (question.length > MAX_QUESTION) {
        throw new HttpError(400, `question takes at most ${MAX_QUESTION} characters`);
      }
      if (!Array.isArray(args.options)) throw new HttpError(400, "options must be a list");
      const options = [...new Set(args.options.map((o) => String(o ?? "").trim()))]
        .filter(Boolean);
      if (options.length < 2 || options.length > MAX_OPTIONS) {
        throw new HttpError(400, `Give 2 to ${MAX_OPTIONS} different options`);
      }
      if (options.some((o) => o.length > MAX_OPTION)) {
        throw new HttpError(400, `An option takes at most ${MAX_OPTION} characters`);
      }
      const multiple = args.multiple === true;
      return Promise.resolve({
        result: { asked: true },
        summary: question,
        question: { question, options, multiple },
      });
    },
  },

};
