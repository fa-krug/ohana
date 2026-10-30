// The assistant's calculator: a small expression language, parsed here and never run as code.
// Numbers and lists of numbers, + - * / % ^ (lists work element by element), variables
// ("rate = 0.035"), and functions for math, statistics, trends and loans / savings
// (Excel's conventions: money paid out is negative, rates are per period).

export type Value = number | number[];

export class CalcError extends Error {}

/** Characters of an expression, expressions per call, numbers in a list, nesting depth. */
export const MAX_EXPRESSION = 2000;
export const MAX_EXPRESSIONS = 50;
export const MAX_LIST = 10_000;
const MAX_DEPTH = 64;

const NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const TOKEN_RE =
  /\s*(?:(\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)|([A-Za-z_][A-Za-z0-9_]*)|(\*\*|[-+*/%^(),[\]=]))/y;

type Token = { kind: "num"; value: number } | { kind: "name" | "op"; value: string };

function tokenize(src: string): Token[] {
  const out: Token[] = [];
  TOKEN_RE.lastIndex = 0;
  while (TOKEN_RE.lastIndex < src.length) {
    if (/^\s*$/.test(src.slice(TOKEN_RE.lastIndex))) break;
    const at = TOKEN_RE.lastIndex;
    const m = TOKEN_RE.exec(src);
    if (!m) throw new CalcError(`Unexpected "${src.slice(at).trim()[0]}" at ${at + 1}`);
    if (m[1] !== undefined) out.push({ kind: "num", value: Number(m[1]) });
    else if (m[2] !== undefined) out.push({ kind: "name", value: m[2] });
    else out.push({ kind: "op", value: m[3] === "**" ? "^" : m[3] });
  }
  return out;
}

// ---- helpers for the functions ----

const isList = (v: Value): v is number[] => Array.isArray(v);

function list(v: number[]): number[] {
  if (v.length > MAX_LIST) throw new CalcError(`Lists can have at most ${MAX_LIST} numbers`);
  return v;
}

/** All arguments as one list of numbers (lists are flattened). */
function flat(args: Value[]): number[] {
  return list(args.flatMap((a) => (isList(a) ? a : [a])));
}

function nonEmpty(name: string, xs: number[]): number[] {
  if (!xs.length) throw new CalcError(`${name} needs at least one number`);
  return xs;
}

function scalar(name: string, v: Value | undefined, fallback?: number): number {
  if (v === undefined) {
    if (fallback === undefined) throw new CalcError(`${name} is missing an argument`);
    return fallback;
  }
  if (isList(v)) throw new CalcError(`${name} expects a number here, not a list`);
  return v;
}

function arg(name: string, v: Value | undefined): Value {
  if (v === undefined) throw new CalcError(`${name} is missing an argument`);
  return v;
}

function optionalList(name: string, v: Value | undefined): number[] | undefined {
  return v === undefined ? undefined : listArg(name, v);
}

function listArg(name: string, v: Value | undefined): number[] {
  if (v === undefined) throw new CalcError(`${name} is missing a list`);
  return isList(v) ? v : [v];
}

/** Applies f to a number, or to each number of a list. */
function each(v: Value, f: (x: number) => number): Value {
  return isList(v) ? v.map(f) : f(v);
}

/** Applies f element by element: number with number, number with list, or two lists. */
function zip(a: Value, b: Value, f: (x: number, y: number) => number): Value {
  if (!isList(a) && !isList(b)) return f(a, b);
  if (!isList(a)) return (b as number[]).map((y) => f(a, y));
  if (!isList(b)) return a.map((x) => f(x, b));
  if (a.length !== b.length) {
    throw new CalcError(`Lists of different lengths (${a.length} and ${b.length})`);
  }
  return a.map((x, i) => f(x, b[i]));
}

const sum = (xs: number[]) => xs.reduce((s, x) => s + x, 0);
const mean = (xs: number[]) => sum(xs) / xs.length;

function sorted(xs: number[]) {
  return [...xs].sort((a, b) => a - b);
}

/** Percentile p (0–100) with linear interpolation between the closest ranks. */
export function percentile(xs: number[], p: number): number {
  if (!(p >= 0 && p <= 100)) throw new CalcError("percentile needs p between 0 and 100");
  const s = sorted(xs);
  const pos = (s.length - 1) * p / 100;
  const lo = Math.floor(pos);
  return s[lo] + (s[Math.min(lo + 1, s.length - 1)] - s[lo]) * (pos - lo);
}

export function median(xs: number[]): number {
  return percentile(xs, 50);
}

/** Variance: of a sample (n - 1), or of the whole population. */
export function variance(xs: number[], population = false): number {
  const n = xs.length;
  if (n < (population ? 1 : 2)) {
    throw new CalcError(`${population ? "varp" : "variance"} needs more numbers`);
  }
  const m = mean(xs);
  return sum(xs.map((x) => (x - m) ** 2)) / (population ? n : n - 1);
}

/** Least squares line through (x, y); x defaults to 0, 1, 2, … */
function regression(name: string, y: number[], x?: number[]) {
  const xs = x ?? y.map((_, i) => i);
  if (xs.length !== y.length) throw new CalcError(`${name}: x and y differ in length`);
  if (y.length < 2) throw new CalcError(`${name} needs at least two points`);
  const mx = mean(xs), my = mean(y);
  let sxy = 0, sxx = 0;
  for (let i = 0; i < y.length; i++) {
    sxy += (xs[i] - mx) * (y[i] - my);
    sxx += (xs[i] - mx) ** 2;
  }
  if (sxx === 0) throw new CalcError(`${name}: all x are the same`);
  const slope = sxy / sxx;
  return { slope, intercept: my - slope * mx, n: y.length };
}

function correl(x: number[], y: number[]): number {
  if (x.length !== y.length) throw new CalcError("correl: the lists differ in length");
  if (x.length < 2) throw new CalcError("correl needs at least two pairs");
  const mx = mean(x), my = mean(y);
  let sxy = 0, sxx = 0, syy = 0;
  for (let i = 0; i < x.length; i++) {
    sxy += (x[i] - mx) * (y[i] - my);
    sxx += (x[i] - mx) ** 2;
    syy += (y[i] - my) ** 2;
  }
  if (!sxx || !syy) throw new CalcError("correl: a list doesn't vary");
  return sxy / Math.sqrt(sxx * syy);
}

/** Rounds half away from zero, like money is rounded. */
function roundTo(x: number, digits: number): number {
  if (!Number.isInteger(digits) || Math.abs(digits) > 12) {
    throw new CalcError("round takes 0 to 12 digits");
  }
  const f = 10 ** digits;
  return Math.sign(x) * Math.round(Math.abs(x) * f + Number.EPSILON) / f;
}

// Loans and savings, as in spreadsheets: pv = present value, fv = future value, pmt = payment
// per period, nper = periods, type 1 = payments at the start of each period.

function fvOf(rate: number, nper: number, pmt: number, pv: number, type: number) {
  if (rate === 0) return -(pv + pmt * nper);
  const g = (1 + rate) ** nper;
  return -(pv * g + pmt * (1 + rate * type) * (g - 1) / rate);
}

function pvOf(rate: number, nper: number, pmt: number, fv: number, type: number) {
  if (rate === 0) return -(fv + pmt * nper);
  const g = (1 + rate) ** nper;
  return -(fv + pmt * (1 + rate * type) * (g - 1) / rate) / g;
}

function pmtOf(rate: number, nper: number, pv: number, fv: number, type: number) {
  if (nper === 0) throw new CalcError("pmt needs nper ≠ 0");
  if (rate === 0) return -(pv + fv) / nper;
  const g = (1 + rate) ** nper;
  return -rate * (fv + pv * g) / ((1 + rate * type) * (g - 1));
}

function nperOf(rate: number, pmt: number, pv: number, fv: number, type: number) {
  if (rate === 0) {
    if (pmt === 0) throw new CalcError("nper needs a payment");
    return -(pv + fv) / pmt;
  }
  const a = pmt * (1 + rate * type);
  const n = Math.log((a - fv * rate) / (a + pv * rate)) / Math.log(1 + rate);
  if (!Number.isFinite(n)) throw new CalcError("nper: the payments never reach the goal");
  return n;
}

function npvOf(rate: number, flows: number[]) {
  return flows.reduce((s, cf, i) => s + cf / (1 + rate) ** (i + 1), 0);
}

/** The rate at which the cash flows (first one now, then one per period) are worth 0. */
function irrOf(flows: number[], guess: number) {
  if (!flows.some((x) => x > 0) || !flows.some((x) => x < 0)) {
    throw new CalcError("irr needs payments in and out");
  }
  const f = (r: number) => flows.reduce((s, cf, i) => s + cf / (1 + r) ** i, 0);
  const df = (r: number) => flows.reduce((s, cf, i) => s - i * cf / (1 + r) ** (i + 1), 0);
  let r = guess;
  for (let i = 0; i < 100; i++) {
    const d = df(r);
    if (!d || !Number.isFinite(d)) break;
    const next = r - f(r) / d;
    if (!Number.isFinite(next) || next <= -1) break;
    if (Math.abs(next - r) < 1e-12) return next;
    r = next;
  }
  // Newton didn't settle: bisection over a wide range.
  let lo = -0.999999, hi = 10;
  if (Math.sign(f(lo)) === Math.sign(f(hi))) throw new CalcError("irr found no rate");
  for (let i = 0; i < 200; i++) {
    const mid = (lo + hi) / 2;
    if (Math.sign(f(mid)) === Math.sign(f(lo))) lo = mid;
    else hi = mid;
  }
  return (lo + hi) / 2;
}

type Fn = (args: Value[], name: string) => Value;

const unary = (f: (x: number) => number): Fn => (args, name) => {
  if (args.length !== 1) throw new CalcError(`${name} takes one argument`);
  return each(args[0], f);
};

const aggregate = (f: (xs: number[], name: string) => number): Fn => (args, name) =>
  f(nonEmpty(name, flat(args)), name);

const FUNCTIONS: Record<string, Fn> = {
  abs: unary(Math.abs),
  sqrt: unary(Math.sqrt),
  cbrt: unary(Math.cbrt),
  exp: unary(Math.exp),
  ln: unary(Math.log),
  log10: unary(Math.log10),
  log2: unary(Math.log2),
  floor: unary(Math.floor),
  ceil: unary(Math.ceil),
  trunc: unary(Math.trunc),
  sign: unary(Math.sign),
  sin: unary(Math.sin),
  cos: unary(Math.cos),
  tan: unary(Math.tan),
  asin: unary(Math.asin),
  acos: unary(Math.acos),
  atan: unary(Math.atan),
  log: (args, name) => {
    const base = scalar(name, args[1], 10);
    return each(arg(name, args[0]), (x) => Math.log(x) / Math.log(base));
  },
  pow: (args, name) => zip(arg(name, args[0]), arg(name, args[1]), (x, y) => x ** y),
  round: (args, name) => {
    const digits = scalar(name, args[1], 0);
    return each(arg(name, args[0]), (x) => roundTo(x, digits));
  },

  sum: (args) => sum(flat(args)),
  product: (args) => flat(args).reduce((p, x) => p * x, 1),
  count: (args) => flat(args).length,
  min: aggregate((xs) => xs.reduce((m, x) => Math.min(m, x))),
  max: aggregate((xs) => xs.reduce((m, x) => Math.max(m, x))),
  mean: aggregate(mean),
  avg: aggregate(mean),
  median: aggregate(median),
  variance: aggregate((xs) => variance(xs)),
  varp: aggregate((xs) => variance(xs, true)),
  stddev: aggregate((xs) => Math.sqrt(variance(xs))),
  stddevp: aggregate((xs) => Math.sqrt(variance(xs, true))),
  percentile: (args, name) =>
    percentile(nonEmpty(name, listArg(name, args[0])), scalar(name, args[1])),

  sort: (args, name) => sorted(listArg(name, args[0])),
  reverse: (args, name) => [...listArg(name, args[0])].reverse(),
  cumsum: (args, name) => {
    let s = 0;
    return listArg(name, args[0]).map((x) => (s += x));
  },
  diff: (args, name) => {
    const xs = listArg(name, args[0]);
    return xs.slice(1).map((x, i) => x - xs[i]);
  },
  growth: (args, name) => {
    const xs = listArg(name, args[0]);
    return xs.slice(1).map((x, i) => {
      if (xs[i] === 0) throw new CalcError("growth: a value is 0");
      return (x - xs[i]) / Math.abs(xs[i]);
    });
  },
  seq: (args, name) => {
    const from = scalar(name, args[0]), to = scalar(name, args[1]);
    const step = scalar(name, args[2], from <= to ? 1 : -1);
    if (step === 0 || Math.sign(step) !== Math.sign(to - from || step)) {
      throw new CalcError("seq: the step doesn't lead from start to end");
    }
    const n = Math.floor((to - from) / step + 1e-9) + 1;
    if (n > MAX_LIST) throw new CalcError(`Lists can have at most ${MAX_LIST} numbers`);
    return Array.from({ length: n }, (_, i) => from + i * step);
  },
  correl: (args, name) => correl(listArg(name, args[0]), listArg(name, args[1])),
  slope: (args, name) =>
    regression(name, listArg(name, args[0]), optionalList(name, args[1])).slope,
  intercept: (args, name) =>
    regression(name, listArg(name, args[0]), optionalList(name, args[1])).intercept,
  forecast: (args, name) => {
    // The trend line of y (one value per period) k periods after the last one.
    const { slope, intercept, n } = regression(name, listArg(name, args[0]));
    return each(args[1] ?? 1, (k) => intercept + slope * (n - 1 + k));
  },

  fv: (args, name) =>
    fvOf(
      scalar(name, args[0]),
      scalar(name, args[1]),
      scalar(name, args[2]),
      scalar(name, args[3], 0),
      scalar(name, args[4], 0),
    ),
  pv: (args, name) =>
    pvOf(
      scalar(name, args[0]),
      scalar(name, args[1]),
      scalar(name, args[2]),
      scalar(name, args[3], 0),
      scalar(name, args[4], 0),
    ),
  pmt: (args, name) =>
    pmtOf(
      scalar(name, args[0]),
      scalar(name, args[1]),
      scalar(name, args[2]),
      scalar(name, args[3], 0),
      scalar(name, args[4], 0),
    ),
  nper: (args, name) =>
    nperOf(
      scalar(name, args[0]),
      scalar(name, args[1]),
      scalar(name, args[2]),
      scalar(name, args[3], 0),
      scalar(name, args[4], 0),
    ),
  npv: (args, name) => npvOf(scalar(name, args[0]), flat(args.slice(1))),
  irr: (args, name) => irrOf(listArg(name, args[0]), scalar(name, args[1], 0.1)),
  cagr: (args, name) => {
    const start = scalar(name, args[0]), end = scalar(name, args[1]);
    const years = scalar(name, args[2]);
    if (start <= 0 || end < 0 || years <= 0) {
      throw new CalcError("cagr needs start > 0, end ≥ 0 and years > 0");
    }
    return (end / start) ** (1 / years) - 1;
  },
};

/** The names the calculator knows, for the tool's description and tests. */
export const FUNCTION_NAMES = Object.keys(FUNCTIONS);

const CONSTANTS: Record<string, number> = { pi: Math.PI, e: Math.E };

/** Parses and evaluates one expression right away (recursive descent). */
class Parser {
  private i = 0;
  private depth = 0;
  constructor(private tokens: Token[], private vars: Map<string, Value>) {}

  private peek(value?: string) {
    const t = this.tokens[this.i];
    return t && (value === undefined || (t.kind === "op" && t.value === value)) ? t : undefined;
  }

  private take(value: string) {
    if (!this.peek(value)) {
      const t = this.tokens[this.i];
      throw new CalcError(t ? `Expected "${value}" before "${t.value}"` : `Expected "${value}"`);
    }
    this.i++;
  }

  run(): Value {
    const v = this.expr();
    const t = this.tokens[this.i];
    if (t) throw new CalcError(`Unexpected "${t.value}"`);
    return v;
  }

  private nested<T>(f: () => T): T {
    if (++this.depth > MAX_DEPTH) throw new CalcError("The expression is nested too deeply");
    try {
      return f();
    } finally {
      this.depth--;
    }
  }

  private expr(): Value {
    return this.nested(() => {
      let v = this.term();
      for (let op; (op = this.peek("+") ?? this.peek("-"));) {
        this.i++;
        const r = this.term();
        v = zip(v, r, op.value === "+" ? (x, y) => x + y : (x, y) => x - y);
      }
      return v;
    });
  }

  private term(): Value {
    let v = this.unary();
    for (let op; (op = this.peek("*") ?? this.peek("/") ?? this.peek("%"));) {
      this.i++;
      const r = this.unary();
      v = zip(v, r, (x, y) => {
        if (op.value === "*") return x * y;
        if (y === 0) throw new CalcError("Division by zero");
        return op.value === "/" ? x / y : x % y;
      });
    }
    return v;
  }

  private unary(): Value {
    return this.nested(() => {
      if (this.peek("-")) {
        this.i++;
        return each(this.unary(), (x) => -x);
      }
      if (this.peek("+")) {
        this.i++;
        return this.unary();
      }
      return this.power();
    });
  }

  private power(): Value {
    const base = this.primary();
    if (!this.peek("^")) return base;
    this.i++;
    return zip(base, this.unary(), (x, y) => x ** y);
  }

  private primary(): Value {
    const t = this.tokens[this.i++];
    if (!t) throw new CalcError("The expression ends too early");
    if (t.kind === "num") return t.value;
    if (t.kind === "name") {
      if (this.peek("(")) {
        const name = t.value.toLowerCase();
        // Own names only: "constructor" isn't a function of the calculator.
        if (!Object.hasOwn(FUNCTIONS, name)) throw new CalcError(`Unknown function "${t.value}"`);
        this.i++;
        const args = this.items(")");
        return FUNCTIONS[name](args, name);
      }
      const v = this.vars.get(t.value) ??
        (Object.hasOwn(CONSTANTS, t.value) ? CONSTANTS[t.value] : undefined);
      if (v === undefined) throw new CalcError(`Unknown name "${t.value}"`);
      return v;
    }
    if (t.value === "(") {
      const v = this.expr();
      this.take(")");
      return v;
    }
    if (t.value === "[") return list(flat(this.items("]")));
    throw new CalcError(`Unexpected "${t.value}"`);
  }

  /** Comma-separated expressions up to the closing bracket. */
  private items(close: string): Value[] {
    const out: Value[] = [];
    if (this.peek(close)) {
      this.i++;
      return out;
    }
    for (;;) {
      out.push(this.expr());
      if (this.peek(",")) {
        this.i++;
        continue;
      }
      this.take(close);
      return out;
    }
  }
}

/** 12 significant digits, so 0.1 + 0.2 is 0.3; errors for results that aren't numbers. */
function tidy(v: Value): Value {
  return each(v, (x) => {
    if (!Number.isFinite(x)) throw new CalcError("The result is not a finite number");
    return Number(x.toPrecision(12)) || 0;
  });
}

export type CalcResult = { expression: string; name?: string; value?: Value; error?: string };

/**
 * Evaluates the expressions in order. "name = expression" stores the result for the later
 * ones, as do `vars`. An expression that fails gets an error; the others still run.
 */
export function calculate(expressions: string[], vars: Record<string, unknown> = {}): CalcResult[] {
  const scope = new Map<string, Value>();
  for (const [name, raw] of Object.entries(vars)) {
    if (!NAME_RE.test(name)) throw new CalcError(`Invalid variable name "${name}"`);
    if (typeof raw === "number" && Number.isFinite(raw)) scope.set(name, raw);
    else if (
      Array.isArray(raw) && raw.every((x) => typeof x === "number" && Number.isFinite(x))
    ) scope.set(name, list(raw));
    else throw new CalcError(`Variable "${name}" must be a number or a list of numbers`);
  }
  return expressions.map((expression) => {
    try {
      if (expression.length > MAX_EXPRESSION) {
        throw new CalcError(`An expression can have at most ${MAX_EXPRESSION} characters`);
      }
      const tokens = tokenize(expression);
      let name: string | undefined;
      if (
        tokens[0]?.kind === "name" && tokens[1]?.kind === "op" && tokens[1].value === "="
      ) {
        name = tokens[0].value;
        tokens.splice(0, 2);
      }
      if (!tokens.length) throw new CalcError("The expression is empty");
      const value = tidy(new Parser(tokens, scope).run());
      if (name) scope.set(name, value);
      return { expression, ...(name ? { name } : {}), value };
    } catch (err) {
      if (!(err instanceof CalcError)) throw err;
      return { expression, error: err.message };
    }
  });
}
