// Instructions for AI agents: GET /families/{id}/agent returns this Markdown page, so a user
// can hand an agent one URL and an API token, and it knows the family's calendar and the API
// with ready-to-use URLs.

import type { FamilyRow, TypeRow } from "@/lib/calendar/store";
import { typeIcon } from "@/lib/calendar/icons";
import { MEMBER_COLORS } from "@/lib/families/colors";

export interface AgentDocInput {
  /** Public API base, e.g. https://ohana.example/api/v1 */
  base: string;
  /** Whether the user who asks is only a viewer. */
  readOnly: boolean;
  family: FamilyRow;
  /** Types of all years. */
  types: TypeRow[];
  /** The family's accounts and people (whose a type is). */
  members?: { id: string; name: string }[];
  /** Today as YYYY-MM-DD. */
  today: string;
  /** Seconds after which an open app shows changes. */
  refreshSeconds: number;
}

const ROLE_HELP: Record<string, string> = {
  needs_cover: "needs cover",
  covers: "covers",
  day_off: "day off",
  none: "normal",
};

function typesTable(types: TypeRow[], members: { id: string; name: string }[]): string {
  if (!types.length) return "_No types in this year yet._";
  const whose = (t: TypeRow) => members.find((m) => m.id === t.member_id)?.name ?? "–";
  return [
    "| id | name | role | member | color | icon |",
    "| --- | --- | --- | --- | --- | --- |",
    ...types.map((t) => `| \`${t.id}\` | ${t.name} | ${t.role} | ${whose(t)} | ${t.color} | ${typeIcon(t)} |`),
  ].join("\n");
}

function membersTable(members: { id: string; name: string }[]): string {
  if (!members.length) return "";
  return ["", "Members (a type's `memberId`):", "", "| id | name |", "| --- | --- |", ...members.map((m) => `| \`${m.id}\` | ${m.name} |`)].join("\n");
}

export function buildAgentDoc(input: AgentDocInput): string {
  const { base, readOnly, family, types, today, refreshSeconds, members = [] } = input;
  const years = [...new Set(types.map((t) => t.year))].sort((a, b) => a - b);
  // Examples use the current year, or the latest year with types if it has none.
  const thisYear = Number(today.slice(0, 4));
  const year = years.includes(thisYear) ? thisYear : (years.at(-1) ?? thisYear);
  const s = `${base}/families/${family.id}`;
  const example = types.find((t) => t.year === year && t.role === "covers") ??
    types.find((t) => t.year === year) ?? { id: "vacation", name: "Vacation" };
  const json = (v: unknown) => "`" + JSON.stringify(v) + "`";

  const typeSections = years.length
    ? years.map((y) => `### ${y}\n\n${typesTable(types.filter((t) => t.year === y), members)}`)
      .join("\n\n") + membersTable(members)
    : "_This calendar has no entry types yet._";

  const read = `## Reading

Every request needs the user's API token: \`Authorization: Bearer <token>\` (the user makes
one in the app under *Account* → *API tokens*). All responses are JSON. Dates are
\`YYYY-MM-DD\`.

- Everything for a year (types, entries, notes): ${s}?year=${year}
- Entries only: ${s}/entries?year=${year} → \`{"${year}-08-03": ["${example.id}"], ...}\`
- Notes only: ${s}/notes?year=${year} → \`{"${year}-12-25": {"icon": "gift", "comment": "Christmas"}, ...}\`
- Types of a year: ${s}/types?year=${year}
- \`?from=YYYY-MM-DD&to=YYYY-MM-DD\` works instead of \`?year=\`.`;

  if (readOnly) {
    return `# Ohana “${family.name}” – instructions for AI agents

The user can only **view** this family's shared year calendar for vacation, public holidays,
sick days and day-care closures. You can read it and answer questions about it, but not change
it: an editor of the family can make them an editor too. Today is ${today}.

${concepts()}

## Entry types (every year has its own)

${typeSections}

${read}
${financeDoc(s, year, false)}`;
  }

  const addOp = {
    action: "add",
    type: example.id,
    from: `${year}-08-03`,
    to: `${year}-08-14`,
    skipWeekends: true,
  };
  const noteOp = { action: "set", date: `${year}-12-25`, icon: "gift", comment: "Christmas" };

  return `# Ohana “${family.name}” – instructions for AI agents

The user gave you **full edit access** to their family's shared year calendar for vacation,
public holidays, sick days and day-care closures. Help them read and plan it. Today is ${today}.

- The API token acts as the user: don't repeat it in public places or share it.
- Read the current state before changing anything, and check the result afterwards.
- For bigger changes (many days, deleting types, renaming) say what you'll do first and ask
  the user to confirm; small, clearly requested changes can be made directly.
- Talk to the user in their language. Changes show up in their open app within about
  ${refreshSeconds} seconds.

${concepts()}

## Entry types (every year has its own)

${typeSections}

Types are referenced by id or by name (case-insensitive); a reference is resolved in the year of
each day, so \`"${example.id}"\` works across years as long as the year has such a type.

${read}

## Changing (HTTP requests with a JSON body)

Send \`content-type: application/json\`. Errors come back as \`{"error": "..."}\` with a 4xx status.

### Entries: \`POST ${s}/entries\`

Body: one op, or \`{"ops": [...]}\` to apply several in order. Example:
${json(addOp)}

| action | effect on the given days |
| --- | --- |
| \`add\` | adds \`type\` or \`types\` (keeps other entries) |
| \`remove\` | removes \`type\` or \`types\` |
| \`set\` | replaces all entries with \`types\` |
| \`clear\` | removes all entries |

Days: \`dates\` (array), \`date\`, and/or an inclusive \`from\`/\`to\` range; \`"skipWeekends": true\`
drops Saturdays and Sundays. Up to 4000 days per request.

### Notes: \`POST ${s}/notes\`

${json(noteOp)} – \`set\` replaces a day's note (icon: an SF Symbol name such as \`gift\`,
\`birthday.cake\` or \`star\`, or \`""\`; anything else is a 400; comment max. 500),
\`{"action": "clear", "dates": [...]}\` removes it. Days and \`{"ops": [...]}\` work as for entries.

### Types (add \`?year=YYYY\`, default: the current year)

- Add: \`POST ${s}/types?year=${year}\` ${
    json({ name: "Day care closed", memberId: null, role: "needs_cover" })
  } (\`memberId\`: whose it is, a member's id or null; left out: yours. Its color is the member's;
  a nobody's type may have its own, \`colorKey\`: ${MEMBER_COLORS.map((c) => c.key).join(", ")} or null (gray).
  \`icon\`: an SF Symbol name, e.g. \`airplane\`; null or left out: the role's)
- Change: \`PATCH ${s}/types/{type}?year=${year}\` with any of \`name\`, \`memberId\`,
  \`colorKey\`, \`role\`, \`icon\` (null: back to the role's), \`position\`
- Delete (also deletes its entries in that year): \`DELETE ${s}/types/{type}?year=${year}\`
- Copy a year's types into another year: \`POST ${s}/types/copy\` ${
    json({ from: year, to: year + 1 })
  }

### Family name: \`PATCH ${s}\` ${json({ name: family.name })}

## Request format

For example, this would add the vacation from the entries section (only send what the user
asked for):

\`\`\`sh
curl -X POST "${s}/entries" -H "authorization: Bearer $TOKEN" \\
  -H "content-type: application/json" -d '${JSON.stringify(addOp)}'
\`\`\`

${financeDoc(s, year, true)}`;
}

function concepts(): string {
  return `## How the calendar works

- A year calendar. Each day can hold **several entries**, each of an **entry type** (name,
  role, icon, and the family member it belongs to, whose color it takes). Every year has its own
  set of types.
- Roles drive the **coverage check**: a weekday with a *${ROLE_HELP.needs_cover}* entry
  (e.g. “Day care closed”) is a gap unless it also has a *${ROLE_HELP.covers}* entry
  (e.g. “Vacation Dad”) or a *${ROLE_HELP.day_off}* entry (e.g. “Holiday”). Role
  *${ROLE_HELP.none}* just marks the day. Role ids: \`needs_cover\`, \`covers\`, \`day_off\`,
  \`none\`. Day-off entries don't count as used vacation days.
- A day can also have one **note**: an icon (an SF Symbol name, e.g. \`gift\`) and/or a
  comment, e.g. \`gift\` Christmas.
  Notes are independent of entries.`;
}

/** The finances: transactions (integer cents, negative = money out), categories, accounts,
 *  transfers, summary. */
function financeDoc(s: string, year: number, edit: boolean): string {
  const f = `${s}/finance`;
  const read = `## Finances

The family also keeps a transactions log. Amounts are integer **cents**, negative for money
going out (\`-4599\` = −45.99 in the family's currency). A transaction can belong to one of
the family's **accounts** (\`accountId\`). Transactions sharing a \`transferId\` are the legs of
one **transfer** between the family's own accounts (e.g. 500 out of checking, 500 into
savings): every income / expense total counts a transfer once by its net (here 0), in the
month of its earliest leg, so only money leaving or reaching the family counts. A transaction
with a \`splitOf\` is a **part** of that split booking (e.g. an order line the bank lists next
to an Amazon "Splitbuchung"); a booking has \`split\` (\`parts\`, \`remainderCents\`). Totals
count the parts with their own categories and only the remainder of the booking.

- Currency, categories and accounts (with \`balanceCents\`): ${f} – categories nest to any
  depth: a category's \`parentId\` is the one it is a subcategory of (null: top level)
- The accounts' balances at the end of a day: ${f}/accounts?at=${year}-06-30 –
  \`{"at", "accounts": [...]}\`
- Transactions (newest first): ${f}/transactions?from=${year}-01-01&to=${year}-12-31 –
  also \`account=<id>\` (or \`none\`), \`category=<id>\` (with its subcategories, or \`none\`),
  \`kind=income|expense|transfer\`, \`q=<text>\`, \`limit\`, \`offset\`.
  Returns \`{"transactions": [...], "total", "incomeCents", "expenseCents"}\`.
- Per month and category: ${f}/summary?from=${year}-01-01&to=${year}-12-31
- Likely transfers not combined yet (same amount out of one account and into another, at most
  4 days apart): ${f}/transfers/suggestions?from=${year}-01-01&to=${year}-12-31 –
  \`{"pairs": [{"out": {...}, "in": {...}}]}\`
`;
  if (!edit) return read;
  return `${read}
Changing: \`POST ${f}/transactions\` with \`{"ops": [...]}\` (applied in order):

- \`{"action": "add", "date": "${year}-03-02", "amountCents": -4599, "payee": "Supermarket", "description": "", "categoryId": "groceries", "accountId": "checking", "note": ""}\`
- \`{"action": "update", "id": "<uuid>", "categoryId": "groceries"}\` (any of the fields above)
- \`{"action": "delete", "ids": ["<uuid>", ...]}\`
- \`{"action": "link", "ids": ["<uuid>", "<uuid>", ...]}\`: combines the transactions into one
  transfer
- \`{"action": "unlink", "ids": ["<uuid>"]}\`: dissolves the transfers they belong to
- \`{"action": "split", "id": "<booking uuid>", "ids": ["<uuid>", ...]}\`: makes the
  transactions parts of the booking
- \`{"action": "unsplit", "ids": ["<uuid>"]}\`: parts become normal transactions again (for a
  booking: all of its parts)

The response has \`inverse\`: ops that undo the request (send them to the same endpoint).
Categories and accounts are referenced by id or name (a category also by its path, like
\`Food > Groceries\`). Ask before deleting or changing many
transactions.

\`POST ${f}/transfers/auto\` with \`{"from": "${year}-01-01", "to": "${year}-12-31"}\` (both
optional) combines the split bookings (order lines without a payee and the booking on the same
account naming the same order number, of the same day or within 4 days; "Splitbuchung" and the transactions of the same
day, account and merchant) and then every suggested transfer in the range; the response has
\`splits\`, \`linked\` and \`inverse\` like above.

Accounts: \`POST ${f}/accounts\` \`{"name", "color": "#22c55e", "icon", "openingCents"}\`,
\`PATCH ${f}/accounts/<id>\` with any of these and \`position\`, \`DELETE ${f}/accounts/<id>\`
(its transactions are deleted too).
`;
}

// ---- the prompt for an outside agent (POST /families/{id}/agent/token) ----

/** Where the API is described (the website's copy describes the latest Ohana). */
export const OPENAPI_URL = "https://ohana.fa-krug.de/openapi.yaml";
export const API_REFERENCE_URL = "https://ohana.fa-krug.de/api-reference.html";

export interface AgentPromptInput {
  /** Public API base, e.g. https://ohana.example/api/v1 */
  base: string;
  family: { id: string; name: string };
  /** Whether the user who asks is only a viewer. */
  readOnly: boolean;
  /** Today as YYYY-MM-DD. */
  today: string;
  /** The agent token and when it expires. */
  token: string;
  expiresAt: Date;
  /** The server's modules that are on (`enabledModules()`). */
  modules: readonly string[];
}

/** Where each module's data starts (paths below the family). */
const MODULE_PATHS: Record<string, (year: string, today: string) => string> = {
  calendar: (year) =>
    `calendar: the family path itself with \`?year=${year}\` (entry types, day entries, notes, events), \`/events?from=&to=\``,
  finance: (year) => `finance: \`/finance\` (accounts, categories), \`/finance/transactions?from=${year}-01-01&to=${year}-12-31\``,
  meals: () => "meals: `/meals/plan`, `/meals/recipes`, `/meals/shopping`",
  chores: (_, today) => `chores: \`/chores\`, \`/chores/agenda?from=${today}&to=${today}&today=${today}\``,
  appointments: () => "doctor appointments: `/appointments`",
  knowledge: () => "knowledge base (the family's paperwork): `/knowledge/documents?q=`",
};

/** The Markdown prompt the app copies for an outside AI agent: the token, the family, the API
 *  basics and where the schema is. Compact: it is pasted into a chat. */
export function buildAgentPrompt(input: AgentPromptInput): string {
  const { base, family, readOnly, today, token, expiresAt, modules } = input;
  const s = `${base}/families/${family.id}`;
  const expires = `${expiresAt.toISOString().slice(0, 16).replace("T", " ")} UTC`;
  const year = today.slice(0, 4);
  // The knowledge base is for editors only (viewers get 404 there).
  const areas = modules
    .filter((m) => MODULE_PATHS[m] && !(readOnly && m === "knowledge"))
    .map((m) => `  - ${MODULE_PATHS[m](year, today)}`);
  const access = readOnly
    ? "**read-only**: the user is a viewer of this family, so every change is refused (403). Only read and answer questions; an editor of the family can make them an editor."
    : "**read and write**, as the user (an editor of this family), except members, people, invites, " +
      "notification channels, the assistant's settings and deleting the family: those stay with the app (403).";

  return `# Ohana: access to the family “${family.name}”

You are helping me with my family's data in Ohana (calendar, finances, meals, chores, …) through
its HTTP API. Today is ${today}. Talk to me in my language.

## Access

- API base: ${base}
- Family: “${family.name}”, id \`${family.id}\`; every path is under \`${s}\`
- Token: \`${token}\`
- Send it with every request: \`Authorization: Bearer <token>\`. Don't show it to anyone or
  write it into files.
- It expires at ${expires} (valid for 1 hour) and works only for this family's API. After
  that (401), ask me to copy a new prompt from the Ohana app.
- Access: ${access}

## First steps

1. Read the family's instructions: \`GET ${s}/agent\` (Markdown: how the calendar works, its
   entry types with ids, finance conventions, example requests).
2. The full API: the OpenAPI schema ${OPENAPI_URL} (readable: ${API_REFERENCE_URL}). It
   describes the latest Ohana; this server's version is at \`GET ${base}/server\`.

## Conventions

- JSON in and out (\`content-type: application/json\`); errors are \`{"error": "…"}\` with a 4xx status.
- Dates are \`YYYY-MM-DD\`; money is integer cents (\`-4599\` = −45.99, negative = money out).
- Where things are (paths below the family's):
  - overview of today and the coming days: \`/overview?today=${today}\`; search: \`/search?q=…&today=${today}\`
${areas.join("\n")}
- Read the current state before changing anything and check the result afterwards. Ask me
  before bigger changes (many items, deleting, renaming); small, clearly asked ones are fine.

## Example (with \`OHANA_TOKEN\` set to the token)

\`\`\`sh
curl -s "${s}/overview?today=${today}" -H "authorization: Bearer $OHANA_TOKEN"
\`\`\`
`;
}
