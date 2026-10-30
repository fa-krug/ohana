// Reads a `pg_dump --data-only` file of family-planner's Supabase database into rows per
// table. Two formats are understood:
//
// - COPY (pg_dump's default): `COPY public.users (id, email, …) FROM stdin;`, then one row per
//   line, tab-separated, `\N` for NULL and backslash escapes, ended by `\.`.
// - INSERT with column names (`--column-inserts`, or `--inserts` on tables pg_dump writes with
//   column names): `INSERT INTO public.users (id, email) VALUES ('a', 'b'), (…);`.
//   A plain `--inserts` statement without column names can't be read reliably (the column
//   order depends on the table's history), so it is rejected with a hint.
//
// Only tables of the `public` schema (or unqualified ones) are kept: a full Supabase dump also
// holds `auth.users` & co., which must not be mistaken for family-planner's `public.users`.
// Every value comes back as text (booleans as "t" / "f", numbers as written) or null; the
// importers convert them (see `pgBool`, `pgDate`, …).

export type PgValue = string | null;
export type PgRow = Record<string, PgValue>;
export type PgTables = Map<string, PgRow[]>;

const COPY_RE = /^COPY\s+((?:"[^"]+"|[\w$]+)(?:\.(?:"[^"]+"|[\w$]+))?)\s*\(([^)]*)\)\s+FROM\s+stdin;\s*$/i;

function unquoteIdent(s: string): string {
  const t = s.trim();
  return t.startsWith('"') && t.endsWith('"') ? t.slice(1, -1).replace(/""/g, '"') : t.toLowerCase();
}

/** "public.users" → { schema: "public", table: "users" }; unqualified names are public. */
function splitName(qualified: string): { schema: string; table: string } {
  const parts: string[] = [];
  let cur = "";
  let quoted = false;
  for (const ch of qualified) {
    if (ch === '"') quoted = !quoted;
    if (ch === "." && !quoted) {
      parts.push(cur);
      cur = "";
    } else cur += ch;
  }
  parts.push(cur);
  if (parts.length === 1) return { schema: "public", table: unquoteIdent(parts[0]) };
  return { schema: unquoteIdent(parts[0]), table: unquoteIdent(parts[1]) };
}

function columnsOf(list: string): string[] {
  return list.split(",").map((c) => unquoteIdent(c)).filter((c) => c !== "");
}

/** Undoes COPY's text-format escapes in one field. */
export function unescapeCopy(field: string): PgValue {
  if (field === "\\N") return null;
  if (!field.includes("\\")) return field;
  let out = "";
  for (let i = 0; i < field.length; i++) {
    const ch = field[i];
    if (ch !== "\\" || i === field.length - 1) {
      out += ch;
      continue;
    }
    const next = field[++i];
    switch (next) {
      case "b": out += "\b"; break;
      case "f": out += "\f"; break;
      case "n": out += "\n"; break;
      case "r": out += "\r"; break;
      case "t": out += "\t"; break;
      case "v": out += "\v"; break;
      case "x": {
        const m = /^[0-9a-fA-F]{1,2}/.exec(field.slice(i + 1));
        if (m) {
          out += String.fromCharCode(parseInt(m[0], 16));
          i += m[0].length;
        } else out += "x";
        break;
      }
      default:
        if (next >= "0" && next <= "7") {
          const m = /^[0-7]{1,3}/.exec(field.slice(i))!;
          out += String.fromCharCode(parseInt(m[0], 8));
          i += m[0].length - 1;
        } else out += next;
    }
  }
  return out;
}

class InsertScanner {
  i: number;
  constructor(private readonly s: string, start: number) {
    this.i = start;
  }
  error(msg: string): never {
    const line = this.s.slice(0, this.i).split("\n").length;
    throw new Error(`pg_dump file, line ${line}: ${msg}`);
  }
  ws(): void {
    while (this.i < this.s.length) {
      if (/\s/.test(this.s[this.i])) this.i++;
      else if (this.s.startsWith("--", this.i)) {
        const nl = this.s.indexOf("\n", this.i);
        this.i = nl < 0 ? this.s.length : nl + 1;
      } else break;
    }
  }
  peek(): string {
    this.ws();
    return this.s[this.i] ?? "";
  }
  expect(ch: string): void {
    if (this.peek() !== ch) this.error(`expected "${ch}"`);
    this.i++;
  }
  word(): string {
    this.ws();
    const m = /^(?:"(?:[^"]|"")*"|[A-Za-z_][\w$]*)(?:\.(?:"(?:[^"]|"")*"|[A-Za-z_][\w$]*))*/.exec(
      this.s.slice(this.i, this.i + 512),
    );
    if (!m) this.error("expected a name");
    this.i += m[0].length;
    return m[0];
  }
  string(escapes: boolean): string {
    // at the opening quote
    this.i++;
    let out = "";
    for (;;) {
      if (this.i >= this.s.length) this.error("unterminated string");
      const ch = this.s[this.i++];
      if (ch === "'") {
        if (this.s[this.i] === "'") {
          out += "'";
          this.i++;
          continue;
        }
        return out;
      }
      if (escapes && ch === "\\") {
        const v = unescapeCopy("\\" + this.s[this.i]);
        out += v ?? "";
        this.i++;
        continue;
      }
      out += ch;
    }
  }
  /** One value: 'text', E'text', NULL, true/false, a number, DEFAULT (→ undefined). */
  value(): PgValue | undefined {
    this.ws();
    let v: PgValue | undefined;
    const rest = this.s.slice(this.i, this.i + 16);
    if (this.s[this.i] === "'") v = this.string(false);
    else if (/^[eE]'/.test(rest)) {
      this.i++;
      v = this.string(true);
    } else {
      const m = /^(?:NULL|true|false|DEFAULT|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)/i.exec(
        this.s.slice(this.i, this.i + 64),
      );
      if (!m) this.error("unexpected value");
      this.i += m[0].length;
      const w = m[0].toLowerCase();
      v = w === "null" ? null : w === "true" ? "t" : w === "false" ? "f" : w === "default" ? undefined : m[0];
    }
    // A cast such as '…'::jsonb or '{}'::text[]: skip it.
    while (this.s.startsWith("::", this.i)) {
      this.i += 2;
      const m = /^[\w ."]+(?:\[\])*/.exec(this.s.slice(this.i, this.i + 64));
      if (m) this.i += m[0].trimEnd().length;
    }
    return v;
  }
}

function parseInsert(text: string, start: number, tables: PgTables): number {
  const sc = new InsertScanner(text, start);
  sc.word(); // INSERT
  sc.word(); // INTO
  const { schema, table } = splitName(sc.word());
  if (sc.peek() !== "(") {
    sc.error(
      `INSERT INTO ${table} has no column names; dump with \`--column-inserts\` or in the default COPY format`,
    );
  }
  sc.i++;
  const cols: string[] = [];
  for (;;) {
    cols.push(unquoteIdent(sc.word()));
    if (sc.peek() === ",") {
      sc.i++;
      continue;
    }
    sc.expect(")");
    break;
  }
  // OVERRIDING SYSTEM VALUE (identity columns) may come before VALUES.
  let kw = sc.word().toUpperCase();
  while (kw !== "VALUES") kw = sc.word().toUpperCase();
  const rows: PgRow[] = [];
  for (;;) {
    sc.expect("(");
    const row: PgRow = {};
    for (let c = 0; ; c++) {
      const v = sc.value();
      if (c >= cols.length) sc.error(`more values than columns in INSERT INTO ${table}`);
      if (v !== undefined) row[cols[c]] = v;
      if (sc.peek() === ",") {
        sc.i++;
        continue;
      }
      sc.expect(")");
      break;
    }
    rows.push(row);
    const p = sc.peek();
    if (p === ",") {
      sc.i++;
      continue;
    }
    if (p === ";") {
      sc.i++;
      break;
    }
    // ON CONFLICT DO NOTHING (--on-conflict-do-nothing)
    const semi = text.indexOf(";", sc.i);
    if (semi < 0) sc.error("unterminated INSERT");
    sc.i = semi + 1;
    break;
  }
  if (schema === "public") {
    const list = tables.get(table) ?? [];
    for (const r of rows) list.push(r);
    tables.set(table, list);
  }
  return sc.i;
}

/** Parses a data-only pg_dump (COPY or INSERT format) into rows per `public` table. */
export function parsePgDump(text: string): PgTables {
  const tables: PgTables = new Map();
  let pos = 0;
  const n = text.length;
  while (pos < n) {
    let end = text.indexOf("\n", pos);
    if (end < 0) end = n;
    const line = text.slice(pos, end).replace(/\r$/, "");
    if (/^INSERT\s+INTO\s/i.test(line)) {
      pos = parseInsert(text, pos, tables);
      continue;
    }
    const copy = COPY_RE.exec(line);
    pos = end + 1;
    if (!copy) continue;
    const { schema, table } = splitName(copy[1]);
    const cols = columnsOf(copy[2]);
    const rows: PgRow[] = [];
    for (;;) {
      if (pos >= n) throw new Error(`pg_dump file: COPY ${table} isn't terminated by "\\."`);
      let e = text.indexOf("\n", pos);
      if (e < 0) e = n;
      const data = text.slice(pos, e).replace(/\r$/, "");
      pos = e + 1;
      if (data === "\\.") break;
      const fields = data.split("\t");
      if (fields.length !== cols.length) {
        throw new Error(`pg_dump file: a row of ${table} has ${fields.length} fields, expected ${cols.length}`);
      }
      const row: PgRow = {};
      cols.forEach((c, i) => (row[c] = unescapeCopy(fields[i])));
      rows.push(row);
    }
    if (schema === "public") tables.set(table, [...(tables.get(table) ?? []), ...rows]);
  }
  return tables;
}

// ---- value conversions ----

export function pgBool(v: PgValue | undefined): boolean {
  return v === "t" || v === "true" || v === "1" || v === "TRUE";
}

/** A Postgres timestamptz / timestamp / date as written by pg_dump, e.g.
 *  "2026-10-31 12:00:00.123456+00", "2026-10-31 12:00:00+05:30", "2026-10-31". */
export function pgDate(v: PgValue | undefined): Date | null {
  if (!v) return null;
  let s = v.trim();
  if (s === "infinity" || s === "-infinity") return null;
  s = s.replace(" ", "T");
  s = s.replace(/(\.\d{3})\d+/, "$1");
  const tz = /([+-])(\d{2})(?::?(\d{2}))?(?::\d{2})?$/.exec(s);
  if (tz && s.includes("T")) {
    s = s.slice(0, tz.index) + `${tz[1]}${tz[2]}:${tz[3] ?? "00"}`;
  } else if (s.includes("T") && !/[zZ]$/.test(s)) s += "Z";
  else if (!s.includes("T")) s += "T00:00:00Z";
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function pgInt(v: PgValue | undefined, fallback = 0): number {
  if (v === null || v === undefined || v === "") return fallback;
  const n = Number(v);
  return Number.isFinite(n) ? Math.trunc(n) : fallback;
}

/** A `date` column ("2026-01-05", possibly with a time part): the YYYY-MM-DD day. */
export function pgDay(v: PgValue | undefined): string | null {
  if (!v) return null;
  const m = /^(\d{4}-\d{2}-\d{2})/.exec(v.trim());
  return m ? m[1] : null;
}
