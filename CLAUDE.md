# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Ohana** is one app for a family: calendar, finance, meals, chores, doctor appointments
and an AI assistant. It is **open source and self-hosted** (server AGPL-3.0, app MPL-2.0). The
repository holds **`server/`**, the server (JSON API, the few sign-in pages, worker; Hono +
SQLite, one Docker image on GHCR), **`apple/`**, the native SwiftUI app for iOS/iPadOS and
macOS, the **only client**: there is no web UI (see *Native app* below), and **`relay/`**, the
push relay fa-krug runs for every server's notifications to the app (see *Push to the app*). Paths in this file are
relative to `server/` unless they start with `apple/`. It replaced `fa-krug/family-planner`,
`fa-krug/cookless` and `fa-krug/findmyappointment`; [docs/plan.md](docs/plan.md) has the
decisions and the phases (all done, phase 8: headless, open source, self-hosted).
Self-hosting: [docs/self-hosting.md](docs/self-hosting.md); the API:
[docs/openapi.yaml](docs/openapi.yaml) (keep it in step with route changes).
**`docs/` is also the website** https://ohana.fa-krug.de (VitePress: `docs/.vitepress/config.mts`,
`cd docs && npm run dev` / `npm run build`; GitHub Pages via `.github/workflows/pages.yml` on pushes
to `main` touching `docs/`): the quick start, guides, API reference (`/api-reference.html`, Redoc
over `openapi.yaml`, served locally), Imprint and privacy policy (`docs/legal/`, contact details in
`docs/.vitepress/operator.ts`; the privacy policy covers the app too: update it when the app starts
using a new permission or service). Links from `docs/` to files outside it stay relative (they
work on GitHub) and become repository links on the site. Keep new pages in the sidebar.
fa-krug's own server runs at https://ohana-app.fa-krug.de.

## Commands

Run in `server/`:

```bash
npm run dev           # server on http://localhost:3000 (tsx watch) + the pages' script (esbuild --watch)
npm run worker        # background worker (tsx worker/index.ts)
npm test              # Vitest (tests/*.test.ts)
npm run typecheck     # tsc --noEmit
npm run build         # bundles client/auth.ts → public/assets/auth.js (the only build step)
npm start             # the server without watching (tsx http/index.ts)
npm run db:generate   # Drizzle migration from lib/db/schema.ts changes
npm run db:migrate    # apply migrations to DATABASE_FILE (default ./data/ohana.db), then db:seed
npm run db:seed       # load the shared units + ingredients (idempotent; also run at server boot)
npm run setup-link -- <email>   # print a new setup link for an account
npm run mock-ai       # scripted OpenAI-compatible stand-in on :4011 (server + worker need AI_ALLOW_PRIVATE_ENDPOINT=1)
```

## Architecture

- **Stack:** Node.js 22, TypeScript run by `tsx` (no compile step; also in the image),
  [Hono](https://hono.dev) on `@hono/node-server`, Drizzle ORM over SQLite (`better-sqlite3`,
  WAL). Schema in `lib/db/schema.ts`, migrations in `drizzle/`. No React, no Tailwind.
- **Two processes, one image:** `docker-entrypoint.sh server` (alias `web`) migrates then serves
  `http/index.ts`; `docker-entrypoint.sh worker` runs `worker/index.ts` (waits for the
  migrations, then loops every `APPT_TICK_SECONDS` (15): the appointment `SearchRunner`, and
  every `WORKER_TICK_SECONDS` (60) `lib/maintenance/cleanup.ts`, the nightly
  `lib/maintenance/backup.ts` and `lib/notifications/daily.ts`; the loop itself ticks every
  `ASSISTANT_TICK_MS` (1000) for the assistant's `ChatRunner`, the meals' `ImportRunner` and the
  calendar's `HolidayRunner` and the knowledge base's `KnowledgeRunner` and `KnowledgeCardRunner`;
  turned-off modules' runners don't run; the same tick runs finance's `BankSyncRunner`). `docker-entrypoint.sh setup-link <email>` prints a setup link. Long-running jobs
  (appointment searches, assistant turns, notifications) belong in the worker, never in a
  request.
- **HTTP (`http/`):** `app.ts` `createApp({ db })` (tests: `app.request(…)`, see
  `tests/http-app.test.ts`) runs every request in a request context
  (`lib/http/request-context.ts`: `AsyncLocalStorage`; `cookies()` / `headers()` /
  `perRequest()` replace `next/headers` and React's `cache`; cookies set there become
  `Set-Cookie`), adds a strict CSP to HTML, mounts `auth-api.ts` (`/api/auth/*`: the sign-in
  pages' JSON routes, all `assertSameOrigin`: login, register, setup, setup-link, logout,
  password, skip-passkey, email, language, pair, invites/accept, and the WebAuthn ceremonies
  `webauthn/{login,register,add,reauth}/{begin,complete}`), `api.ts` (`/api`: health,
  `/v1/server`, `/v1/me[/…]`, `/v1/admin/…`, `/v1/invites/…`, `POST /v1/families`, the
  separate family routes, the family API, `/images/…`), `pages/routes.tsx` and the static
  files of `public/` (`assets/auth.css`, the built `assets/auth.js`, icons, a `sw.js` that
  unregisters the old web app's service worker).
- **Pages (`http/pages/`):** server-rendered with `hono/jsx` (`jsxImportSource` in tsconfig),
  `layout.tsx` (`Layout`, `Card`, `Field`, language switch), `auth.tsx` (`/login`, `/setup`,
  `/setup-link/:token`, `/invite/:code`, `/onboarding`, `/device/pair`), `account.tsx` (`/`:
  signed in, open the app; `/account[?state=]`: passkeys, email (password or passkey reauth),
  password, sign out; with `state` (the app's, `validPairState`) changes end at
  `ohana://account-callback?state=…&changed=passkey|email|password`; `/f/*`: an *Open the
  app* button for `ohana://f/*`, the target of notification links). Forms are
  `data-form="…"`, handled by `client/auth.ts` (`@simplewebauthn/browser`, `homeFor`),
  bundled by `scripts/build-client.ts`. Texts are rendered by the server (`getI18n()`).
- **Auth (`lib/auth/`):** passkeys (`@simplewebauthn`, ceremony state in a signed cookie) and
  argon2id passwords; family-planner's `pbkdf2-sha256$…` hashes are still verified and replaced
  at the next sign-in. Sessions (the sign-in pages' browser), API tokens (the app, scripts) and
  setup links are rows of `auth_tokens` (`kind` session | api | setup) holding only the SHA-256
  of the token (`tokens.ts`). A session opened with a setup link has `canReset` (may set a
  password without the old one). `session.ts`: `getAuth()` (session cookie of the current
  request, memoized per request and cookie value), `getApiUser(req)` (Bearer API token).
  `config.ts`: `WEBAUTHN_RP_ID` / `WEBAUTHN_ORIGIN` default to `APP_URL`'s host / origin,
  `cookieSecure()` when `APP_URL` is https. Password sign-in is rate limited
  (`rate-limit.ts`). Onboarding steps: SET_CREDENTIALS (admin-created account, via setup link)
  → ADD_PASSKEY (optional) → COMPLETED. The first account (`/setup`, only while there are no
  users) is an admin.
- **Families (`lib/families/`):** every piece of data belongs to a family; members are
  `editor` or `viewer` (`roles.ts`: `requireRole` gives 404 to non-members, 403 to viewers
  where an editor is needed; an `Actor` with `admin: true` is used only by the admin actions).
  A family always keeps an editor.
  Members without an account (children, grandparents) are rows of `family_people`
  (`people.ts`: names unique per family, editors add / edit / remove); adding one may create
  an invite for them (`invites.person_id`, `createInvite(..., personId)`): accepting it makes
  the account a member and deletes the person (the membership takes their birthday, a
  nameless account their name). Birthdays ("YYYY-MM-DD", optional, not in the future) are on
  `family_people` and per family on `family_members` (`setMemberBirthday`: members set their
  own, editors anyone's); `birthdays.ts` (browser-safe: `ageOn`, `birthdaysIn` a range, 29 Feb
  → 28 Feb in other years). `familyNames` (accounts + people, with ids and birthdays) are the
  "who is it for" chips when booking an appointment, the members the assistant's system
  prompt names with their ages, and the birthdays of the calendar (GET `/families/{id}`
  `birthdays` by day via `dayExtras`, shown by the app's calendar)
  and of the overview (next 30 days, `familyDashboard`). **Colors:** every account and person
  has one of a fixed palette (`colors.ts`, browser-safe: `MEMBER_COLORS` keys → hex,
  `pickMemberColor`: the first unused, else the least used; `member-colors.ts`
  `nextMemberColor`), `family_members.color` / `family_people.color`; new members get a free
  one, accepting a person's invite keeps theirs; members change their own, editors anyone's
  (`PATCH /household/members/{id}` / `people/{id}` `color`; duplicates allowed). **Photos**
  (`photos.ts`): `family_members.photo` / `family_people.photo` (path under `MEDIA_ROOT`,
  `members/<familyId>/<id>_<ms>.webp`, a 512² WebP; `photo` in every member DTO, the app loads
  `/api/images/<photo>`, `serveImage` gives it to the family's members only). The upload is kept
  too (`photo_original`, upright, ≤ 2048 px, `…_original.webp`) with the chosen crop
  (`photo_crop`, JSON `{x, y, w, h}` fractions of the original; household DTOs `photoOriginal`,
  `photoCrop`): `PUT /household/members/{id}/photo[?x=&y=&w=&h=]` (own, editors anyone's) and
  `…/people/{id}/photo` (editors), raw image or multipart `image` (`lib/api/upload.ts`, shared
  with recipe photos; no crop: sharp's attention), `PATCH …/photo {crop}` re-cuts the square from
  the original (409 without one), `DELETE`; replacing / removing a member, person or family deletes
  the files, accepting a person's invite keeps theirs.
- **Family REST API** (`lib/api/family-api.ts`, family-planner's `handler.ts`): `http/api.ts`
  runs `createFamilyApi([...routes])` for `/api/v1/families/{id}[/…]`; the first route is
  `handleDisabledModules` (`lib/api/disabled-modules.ts`).
  Each module adds a route function `(ctx: Ctx) => Promise<Response> | null` (null: not my
  path) to that list. `Ctx` has `db`, `store` (calendar part of family-planner's `Store`),
  `finance` (its finance part), `rest` (path after the id), `principal`,
  `requireUser()`, `load(need)` / `loadWith(need, query)` with `need` = `edit` | `view`
  (404 for non-members — admins too —, 403 "You can only view this family" for viewers).
  Signed in by an API token (Bearer; the session cookie is still accepted, writes with it need
  a same-origin request). The separate routes (`/recipes`, `/geocode`, the
  autocompletes, `/api/images`) take API tokens only (`lib/families/api.ts`
  `requireApiUser` / `requireFamilyApi`). `HttpError` / `AuthError` / `ZodError` become
  `{ "error": … }`. Input helpers in `lib/api/http.ts`. Paths and JSON shapes are
  family-planner's, so its scripts keep working.
- **Calendar (`lib/calendar/`):** family-planner's vacation module.
  `store.ts` is the calendar part of its `Store` interface over Drizzle (`DrizzleCalendarStore`,
  snake_case rows, promise API); `vacation.ts` (types per year, entries, notes),
  `family-routes.ts` (GET/PATCH family, `export`/`import`), `gaps.ts` (`gapDays`), `dates.ts` and
  `core.ts` (pure client logic) are ported with few changes; there is no calendar feed (the app
  syncs with Apple Calendar instead). Tables `cal_entry_types` (PK
  family+year+id), `cal_entries` (with the day's `year`, composite FK to its type: deleting a
  type cascades to its days; never `INSERT OR REPLACE` a type), `cal_notes`. A type belongs to
  a member (`member_user_id` / `member_person_id`, API `memberId`; POST without one: the
  caller; removing the member clears it) and takes the member's color: `listTypes` derives
  `color` from it (`typeShade`: their first type of the year by position the color itself, each
  further one another shade); a nobody's type (e.g. the holiday types) may have a palette color
  of its own (`color_key`, API `colorKey`, shaded per color the same way; none: gray; giving the
  type to a member clears it; the type editor shows the palette for "Nobody"); GET
  `/families/{id}` lists `members` with their colors. Export files name a type's member (matched
  by name on import) and keep `colorKey`.
  Icons are SF Symbol names the app draws (`icons.ts`): a type's `icon` (null: its role's,
  `ROLE_ICONS`; the API always answers one) and a note's `icon` ("" or a symbol; an import's
  emoji moves into the comment).
  `createFamily` adds the preset types (`presets.ts`, the creator's) in the creator's
  language. Export / import of the family file: `GET /export`, `POST /import` (checks in
  `lib/calendar/export-file.ts`; family-planner's Clone isn't ported); the overview shows
  `lib/calendar/summary.ts`.
- **Holidays (`lib/calendar/holidays/`):** public and / or school holidays of the family's region
  imported as day entries. `openholidays.ts` (OpenHolidays client, `HOLIDAYS_URL`, default
  openholidaysapi.org, empty = off, `GET /api/v1/server` `holidays`; `parseHolidays` keeps only
  FullDay `Public` / `School` ones; `appliesTo`: nationwide, or a subdivision S with region
  `=== S` or starting with `S-`), `region.ts` (Photon reverse look-up of the home coordinates →
  country + state matched by folded name against the subdivisions, then city / county /
  district against their children, no match: the country, unknown country: unsupported;
  `regionNames`), `settings.ts` (`holiday_settings`: kinds, `region`, `region_auto` /
  `region_from`, `region_names`, `synced_region` / `import_from`, `requested_at`, `status`; the
  DTO; `holidaysByDay` for GET `/families/{id}` `holidays`, from `holiday_cache` only),
  `sync.ts` (worker: `HolidayRunner.tick` picks families with `requested_at` due in the fast
  loop, one round at a time; `requestDailyHolidaySyncs` in the 60 s tick; `syncFamily`: Jan 1
  this year – Dec 31 next, into the year's type `holiday` / `school-holidays` (made when missing:
  last year's copied, else the preset; never changed), `holiday_days` records what it wrote (a
  deleted day stays deleted, a day the source drops from today on goes; a day the user already
  had in the type isn't recorded, so it stays theirs); `pruneHolidays`: a kind
  off or another region removes recorded days from today on, a new region imports from today
  (`import_from`); failures: status `failed`, retried after `RETRY_MS`; `holiday_cache` per
  country / kind / year, refetched after 7 days, an old copy used when it fails), `routes.ts`
  (`GET/PUT /holidays`, `GET /holidays/regions[?country=]`; PUT detects the region inline with a
  5 s limit and prunes at once). The family file import clears `holiday_days` and asks for a
  sync (`entriesReplaced`); `setHomeAddress` asks for one (`homeChanged`). Tests inject
  `HolidaysEnv` (`source`, `reverse`); fixtures in `tests/fixtures/holidays/`. App:
  `Features/Calendar/CalendarHolidaysSection.swift` (Settings → Calendar → Holidays: the two
  toggles, the region picker sheet, reloads the calendar while `status` is `pending`; hidden in
  the demo and without the server's `holidays`); the names show on days wherever birthdays do
  (`CalendarStore.holidays`, `CalendarText.holiday`).
- **Finance (`lib/finance/`):** family-planner's finances. `store.ts`
  is the finance part of its `Store` over Drizzle (`DrizzleFinanceStore`, snake_case rows,
  promise API; `replaceFinance` runs inside the calendar store's `replaceContents`, so an
  export file's import is all or nothing), `finance.ts` (routes under
  `/api/v1/families/{id}/finance/...`, `applyTransactionOps` with `inverse` undo ops, transfer
  groups and split bookings with net counting `netItems`, `matchSplits` / `matchTransfers` /
  `autoCombine`, import hashes, `financeSummary`, benchmark, `exportFinance` /
  `parseFinanceImport` / `copyFinance`), `category-tree.ts`, `csv.ts` and `money.ts`
  (shared with the client) are ported with few changes; `summary.ts` is the overview card,
  `presets.ts` the default categories `createFamily` adds (creator's language). Tables
  `fin_settings` (currency, CSV mappings and benchmark as JSON text), `fin_categories` (tree
  via `parent_id`), `fin_accounts`, `fin_transactions` (`transfer_id`, `split_of`,
  `import_hash` unique per family, `source` manual | csv | bank: where it came from, in the DTO,
  the export file and the `source` filter of `findTransactions` (list route, the assistant's
  `list_transactions` / `analyze_transactions`); migration 0026 guessed it for older rows: hashed
  ones added to a linked account after linking bank, other hashed ones csv). References inside a family are composite FKs without an
  action (SQLite can't null one column of a composite key): the store moves or clears them
  before deleting (category → parent, parts of a deleted booking become normal). Within a
  day transactions list newest created first, then in insertion order (rowid); one request's
  ops share one `created_at`. CSV files are parsed by the app; the server stores the saved
  formats (`fin_settings.csv_mappings`). Auto-categorize calls the assistant's
  `POST …/ai/categorize` (so it's off with the assistant). Receipts are scanned and read in
  the app only (`apple/…/Finance/ReceiptScanner.swift`: VisionKit's document camera, Vision
  text recognition, `ReceiptParser`; optionally also a PDF, see Scanning); it saves a plain
  transaction, then sorts it with `…/ai/categorize` (`ids`).
  **Bank sync** (`lib/finance/bank/`): an account can be linked to a bank (`fin_bank_links`,
  PK family + account, composite FK to `fin_accounts` ON DELETE CASCADE: deleting / clearing /
  importing a family file drops it; never exported): `provider`, `credentials` (sealed JSON, never
  in a DTO or log), `iban` or `card` (a credit card's last 4 digits), `session` (sealed refresh
  token, ~20 min: no new TAN), `synced_through`, `last_sync_at`, `synced_from` (the first sync's
  first day: a floor), `bank_balance_cents` / `bank_balance_at` (the booked balance the last sync
  that brought one told; cleared with the history), the lockout guards `unconfirmed_tans` /
  `login_refused`. Providers implement
  `types.ts` `BankProvider` (`fetchStatement` with `SyncHooks`), registry `providers.ts`; the only
  one is `comdirect.ts` (its REST API: password grant → session → validate asking for
  P_TAN_PUSH → push polled / photoTAN or SMS TAN typed → PATCH → `cd_secondary` → v2 balances
  (by IBAN, else the only Girokonto; its `balance`, the booked Kontostand, is
  `BankStatement.balanceCents`, never `availableCashAmount`, which takes pending bookings off) →
  BOOKED transactions, 500 per page, `min-bookingDate`;
  `mapTransaction` / `remittanceLines`: exact cents, payee by direction, 37-char remittance
  windows, SEPA reference lines dropped; a card: `allbalances?productType=CARD` (with each card's booked
  `balance.balance`, the statement's `balanceCents`, negative what's spent), each card's
  suffix from `GET /api/banking/v1/cards/{cardId}` (`primaryAccountNumberSuffix`), then
  `…/cards/{cardId}/transactions` (both undocumented; one request of ≤ 500, no paging: 422),
  `mapCardTransaction`: day = `transaktionDate`, payee the merchant line, accountRef = cardId;
  injected fetch, a timeout per request). Routes
  `routes.ts` (from `handleFinance`): `PUT/DELETE /finance/accounts/{id}/bank` (blank secrets
  keep the stored ones; saving resets the guards; `iban` or `card` (last 4 digits kept, 400 for
  both / fewer digits; a changed one restarts the history)), `POST/GET/DELETE …/bank/sync`,
  `POST …/bank/sync/tan`; the account DTO's `bank` ({provider, iban, card, lastSyncAt, balanceCents,
  balanceAt}, from
  `listAccounts`' join); a linked account refuses `POST /finance/import` (409). Syncs are
  `fin_bank_syncs` rows (`queue.ts`: waiting → running → tan → done | failed, `step`, `tan`
  challenge, `tan_input` sealed until used, `result`; finished ones pruned after a day by
  `cleanup`), run by the worker's `runner.ts` `BankSyncRunner` (CAS claim + run token + a lease
  renewed every tick; cancelled / deleted rows abort it). **Lockout safety** (comdirect locks
  after 5 unconfirmed TAN challenges or 3 wrong TANs): validate and the TAN PATCH are never
  retried, a lost lease or a stopping worker marks the sync failed ("Interrupted"), never re-run;
  each challenge is counted before it is asked for, a confirmed TAN resets it, no sync starts at
  3 or after a refused login until the link is saved again. Which days: later syncs from
  `synced_through` − 14 days but never before `synced_from`, the first of an account with
  transactions from its latest day on, of an empty one 2 years back (saving another IBAN / card /
  provider clears both; links synced before it existed got `synced_through` as their floor); on
  days up to `synced_from` a bank row with the day and amount of one of the account's other
  transactions (not a split's part) counts as that one, one to one, its own (same hash) first,
  else the one with its payee (`matchExisting`: a CSV file's last day isn't doubled). A **full
  sync** (`POST …/bank/sync {full: true}`, `fin_bank_syncs.full`; the user's explicit "import all
  transactions" after a CSV import) asks for `FULL_SYNC_DAYS` (10 years) back and matches the same
  way on every day fetched, but *adopts*: the matched transaction takes the bank row's import hash
  (its text, category, note, transfer and split stay), only unmatched rows are added, the
  account's other transactions from the bank's first row on are counted (`result.adopted` / `unmatched`) and left
  alone; adopted rows become `source` bank, so the account's manual / csv rows in the bank's
  days are the ones to look at; `synced_from` becomes its first day. With the statement's
  `balanceCents` (and rows) a full sync also sets the account's `opening_cents` (`setOpening`,
  `result.openingCents {from, to}`; a normal sync never does): the bank's balance minus the sum of
  its rows, minus the account's transactions (not split parts) before the bank's first day —
  from the bank's rows, not the account's sum, so leftover CSV duplicates don't skew it; the
  balance is the bank's from its first day on, and today's once the "Not from the bank" rows in
  its days are deleted. A comdirect card gives only its newest 500 rows: when
  there are more, `BankStatement.from` says from which day they're complete (the oldest booking
  day's rows dropped, and those bought before `from`, so the opening balance adds up). Import through `importTransactions`
  (shared with the CSV route, autoTransfers on); hashes
  `"bank|<provider>|<bank account id / cardId>|<reference>"`, rows without a reference by
  `importHashes`; a card's Visa-Kartenabrechnung pairs with the Girokonto's debit by
  autoTransfers. Tests: the fake comdirect `lib/test/comdirect.ts` (accounts and cards). App:
  `FinanceAccountEditor`'s Bank connection section (`FinanceBankProvider`: the providers and their
  fields; one field "IBAN or card number"; "Balance differs: Bank … · Ohana …" when the link's
  `balanceCents` isn't the account's balance; after *Import All* the opening field takes the new
  value), `FinanceIntake` (pure: Import CSV, Sync of the shown
  account; with Scan Receipt first they're the iPad / Mac toolbar's *Add from…* menu and the
  import section of the iPhone's More; the CSV sheet leaves linked accounts out; an import always
  remembers its format and sorts into categories, no toggles), `FinanceBankSyncSheet`
  (starts the sync, polls it every second: push / photoTAN / SMS TAN, then the CSV import's sort
  into categories; `full`: the account editor's *Import All Transactions*, after a confirmation,
  shows the adopted / added / unmatched counts and "Opening balance set to …" (was …); the rows show their `source` as an icon,
  `FinanceSource`, and the list's Origin filter, `FinanceFilter.Source`, has "Not from the bank").
- **Assistant (`lib/assistant/`):** family-planner's `ai/*`. Tables
  `ai_settings` (keys sealed with `getSecretBox()`), `chats` (status, lease `run_token` /
  `run_until`, `stop`, JSON `context` / `activity` / `notes` / `usage` / `queue`, `rev`),
  `chat_items` (what the chat shows, by `seq`, with the `rev` it changed in), `chat_messages`
  (what the model gets, append-only, summaries among them) in `lib/db/schema/assistant.ts`;
  `store.ts` is the AI part of the `Store` (`DrizzleAssistantStore`, `ctx.assistant`; queue and
  item revisions in immediate transactions). Routes: `routes.ts` `handleAi(env)` (settings,
  models, test, categorize, letter, `/agent`) and `chat-routes.ts` (chats; they save the message and
  leave the chat running without a holder, then stream it from the database). **Turns run
  only in the worker:** `runner.ts` `ChatRunner.tick()` claims waiting chats (`pendingChats`,
  `claimChatNow`) and runs `chats.ts` `Runner` (the tool loop `chat.ts` `runChat` against
  `provider.ts`, items/messages saved as it goes, lease renewed, stop/delete noticed per
  tick). `prepareTurn` builds the instructions and tools; viewers and `allow_writes: false`
  get only the tools that read. Tools by module in `tools/` (`calendar.ts`, `events.ts`
  (cal_events), `finance.ts`, `meals.ts`, `appointments.ts`, `knowledge.ts`, `general.ts`, `web.ts`, registry
  `index.ts`; `runTool` turns `HttpError` / `AuthError` / `ZodError` into the model's
  `{"error"}`); every change returns undo steps (requests on the family API the client
  replays; meals' and appointments' undo routes are `lib/meals/family-routes.ts`
  `handleMeals` (`/meals/recipes/{id}`,
  `/meals/plan/restore` with `meal-plan/snapshot.ts`, `/meals/plan`) and
  `lib/appointments/family-routes.ts` (`/appointments/searches/{id}`); POST `/events` with
  `searchId` + `resultId` puts a booking back). `ToolContext` carries `userId` (the chat's
  user: the lib functions' `Actor`), `today`, `now` and `lookups` (Doctolib / Photon; tests
  fake them via `AiEnv.lookups`). The system prompt (`chat.ts`) lists the meal tags and the
  home address. **Reminders** (`tools/reminders.ts`, phase 10): the app sends the device's open
  reminders with each message (`reminders` in the chat context: lists, items, the family's shopping
  list id; `cleanReminders` caps it; each message replaces it, so without it the tools are off);
  `get_reminders` reads it, `edit_reminders` resolves ops against it and, like `ask_user`'s
  question, ends the step with a `kind: "reminders"` item the app shows as a confirmation card;
  the app applies the ops through EventKit and answers `POST /ai/chats/{id}/reminders`
  (`{id, applied, results, reminders}`), which becomes the tool's result (a new message instead
  marks it `skipped`). **Apple Calendar** (`tools/apple-calendar.ts`) works the same way: the
  `appleCalendar` context (the device's calendars and their events from a week back to 90 days
  ahead, `cleanAppleCalendar`; `ohana: true` marks the calendar the family syncs with),
  `get_apple_calendar`, `edit_apple_calendar` (add / update / delete, `span` this | future on an
  occurrence "id@day", `rrule` via `lib/calendar/rrule.ts`) → `kind: "calendar"` card →
  `POST /ai/chats/{id}/calendar`; the waiting-item code (`openEdit`, `waitingFor`) is shared by
  all of them. **Notes** (`tools/notes.ts`) the same way: the app sends `knowledgeFolder` (the
  family's folder id, when linked on the device) in the context; with it, the knowledge tools and
  writes `edit_knowledge_notes` creates Markdown notes (`path`, ".md" added) or changes a .md /
  .markdown / .txt one of a single page (by `documentId` or `path`: `content`, `append` or
  `replace` [{find, with}] each found once, and / or `tags`), resolved against the stored text
  (updates of one note merged; whole new text plus the stored `baseHash`) → `kind: "notes"` card →
  `POST /ai/chats/{id}/notes` (result ids are the paths). **Suggestions** (`tools/suggestions.ts`): from a letter, school note or invitation (the
  app scans it and sends only its text, as a text attachment) `suggest_items` offers events
  (checked with `lib/calendar/events.ts` `checkEventFields`, so `POST /events` takes them),
  tasks and deadlines (Reminders, so only with the `reminders` context; `list` null = the
  device's default list) → `kind: "suggestions"` card, the user ticks which to add, the app adds
  them (events via `POST /events`, the rest through EventKit) and answers
  `POST /ai/chats/{id}/suggestions`; an unticked one is `{ok: false, declined: true}`. The
  letter scan's sheet gets the same items without a chat: `letter.ts`, `POST /ai/letter {text,
  today?, lang?}` (editors; one completion with the family's model, items checked one by one with
  `resolveSuggestion`, wrong ones dropped, tasks' `list` null; body `tags`: the user's existing
  tags) → `{ai, source?, items, filing}` (`filing`: title, date, whose it is, tags only of `tags`). `notify.ts` is the "assistant turn finished" notification (`RunnerEnv.turnEnded`
  from the `ChatRunner`; `chats.seen_at`, set every 15 s by a follower, says someone looks).
  `net.ts` refuses private addresses (`AiEnv.modelNet` may allow them for the endpoint with
  `AI_ALLOW_PRIVATE_ENDPOINT`). `toolsFor` leaves out the tools of turned-off modules
  (`toolEnabled`). **Knowledge** (phase 12): `search_knowledge` / `read_knowledge` (read-only,
  `needsKnowledge`: only with `ToolContext.knowledge`, i.e. `knowledgeForUser`: an editor, the
  module on, a folder; never viewers) give every passage a `ref` "k:<chunkId>"; the system prompt
  asks for `[[k:<chunkId>]]` after each statement from them; `requireKnowledge` re-checks the
  user's role and the module at run time. The refs a tool run returns (`ToolResult.refs`, those
  still in the result the model got) come with `tool_result` and are recorded in
  `chats.knowledge_refs` (migration `0023`); an imported history adds none (its knowledge calls
  stay, inert). The `Runner` checks each assistant item it saves (`sources.ts` `checkSources`,
  `RunnerEnv.sources` → `chunkSources`): U+E000 / U+E001 (the app's placeholders) go, markers
  (spaces inside allowed) are written `[[k:<id>]]` when recorded and the chunk is the family's,
  else taken out; the item gets `sources` (`ref`, `chunkId`, `documentId`, `name`, `path`, `page`,
  `quote` = the whole chunk, `excerpt` ≤ 300 chars of it: `excerptOf`, the 1–3 sentences sharing
  most words with the statement before the marker, or a matching card fact's quote, else the
  first sentence). Only the saved copy is checked (the streaming text keeps half-written
  markers); the model's messages keep the raw text; imported chats' items lose their markers. Tests use
  `lib/test/assistant.ts` (fake fetch + `lib/test/mock-ai.ts`, a ticking `ChatRunner`);
  `npm run mock-ai` serves the mock for trying it out.
- **Secrets (`lib/secrets.ts`):** `SecretBox` (port of family-planner's): AES-256-GCM,
  `v1:<base64 iv+ciphertext+tag>`, keyed by `ENCRYPTION_KEY` or else HKDF(`AUTH_SECRET`,
  info "ohana-secrets"). `getSecretBox()` for channel tokens / SMTP passwords and the AI / search keys. Stored secrets never go back to the browser: DTOs say `hasToken`, a blank field on
  edit keeps the stored value.
- **Notifications (`lib/notifications/`), family-wide:** `notification_channels` (Pushbullet,
  Pushover, Telegram, email/SMTP, ntfy; `token` sealed). `channels.ts` CRUD (editors),
  `notifyFamily(db, familyId, message, { channelIds?, send? })` in `index.ts` sends to the
  enabled channels (`channelIds: []` = none, omitted = all); a failing channel is logged and
  counted, never thrown. `send.ts` holds the network senders (untested); `locale.ts` picks the
  family's language (its longest-standing editor's). **ntfy** (`NTFY`): `target` is the topic
  URL (`validNtfyTopicUrl`), `token` an optional access token; `ntfyRequest` builds the publish
  request (title RFC 2047-encoded when not ASCII). Set up in the app (Settings → Household).
  `notifyFamily`'s `app` option (`true` or `{ userIds }`) also pushes to the members' app
  devices (`lib/push`); `notifyEvent` passes the pref's `app`, `notifyRun` the search's
  `notifyApp`, the assistant's turn notification only the chat user's devices.
- **Push to the app (`lib/push/`, `relay/`, phase 9):** APNs needs the app developer's key, so
  every server sends through fa-krug's relay (`PUSH_RELAY_URL`, default
  `https://ohana-push.fa-krug.de`, empty = off; `GET /api/v1/server` `push: { relay } | null`).
  The app registers its APNs token with the relay (`POST /v1/register` → sealed `relayToken`),
  then `PUT /api/v1/me/push` (`lib/push/app-routes.ts`, on the account router) gives the server
  the relay token and a per-device AES-256 key; `push_devices` (one per API token, cascade: sign
  out removes it; both secrets sealed; `muted_family_ids`). `deliver.ts` `pushToFamily` seals
  `payload.ts` `{v, title, body, path, familyId, event}` per device (12-byte IV + ciphertext +
  tag, base64 = CryptoKit's combined box; shortened to 3000 bytes), opaque collapse ids
  (hash of key + `Message.collapseKey`), sends through `relay.ts` (`RelayClient`, injected in
  tests as `push`/`relay`); `gone` / `invalid` deletes the device (the app registers again at
  start). Prefs: `notification_prefs.app`, `appt_searches.notify_app` (both optional in input:
  an older app keeps them). `relay/` is its own Hono service (stateless, AGPL, image
  `ghcr.io/fa-krug/ohana-relay`, `.github/workflows/relay.yml`, tests with a fake APNs client;
  `relay/README.md` has the protocol). App: `Core/Push/` (`PushNotifications`: enable / renew
  at start / mute / test, tap → `AppModel.open`; `PushPayload` + `PushKey`, shared with the
  `OhanaNotificationService(-macOS)` extension targets, which decrypt with the key from the
  shared Keychain group), `App/AppDelegate.swift` (the APNs token), `Shell/PushSettingsSection`,
  `OhanaPushRelay` in the Info.plists; `PUSH_FALLBACK` is the relay's visible fallback string.
- **Appointments (`lib/appointments/`)**, port of findmyappointment: `doctolib/` (JSON client,
  profile cache), `jameda/` (HTML client, offline term list), `sources/` (fan-out, dedup,
  ignore keys), `pipeline.ts` (`runPipeline`: never throws once the run exists; per-provider
  failures are skipped, a failed source fails the run), `notify.ts` (notify only on change,
  or with `notifyOnlyEarlier` against `earliestSeen`, advanced only after a successful send;
  deep links to `/f/<id>/appointments/<searchId>[/slots/<resultId>]`), `searches.ts` (CRUD,
  ignore, `requestRun`), `serialize.ts`, `scheduling.ts` (interval + jitter, cron matcher).
  Every outbound request has a timeout (`http.ts`). **Scheduling lives in the worker**
  (`tasks.ts`, `runner.ts`): `dueSearches` + `claimSearch` (a compare-and-swap UPDATE that
  takes a lease `locked_until`, clears `run_requested_at` and advances `next_run_at`, so no
  search runs twice), `runClaimed` (pipeline → notify → re-anchor → release), runs are started
  without awaiting (max `APPT_MAX_CONCURRENT`); stale RUNNING runs are marked interrupted at
  start, runs older than 30 days pruned daily. "Run now" only sets `run_requested_at`. Tables
  `appt_*` (`lib/db/schema/appointments.ts`); the family's home address (`families.home_*`,
  `lib/families/home.ts`, Photon-geocoded) gives the distance on the slot page. App routes in
  `lib/appointments/app-routes.ts`; autocomplete routes in `http/api.ts` (members; API token).
- **Schema files:** `lib/db/schema.ts` holds accounts + families and re-exports one file per
  module from `lib/db/schema/` (`notifications.ts`, `appointments.ts`, `finance.ts`,
  `meals.ts`, `connections.ts`, `chores.ts`, `digest.ts`, `knowledge.ts`,
  `assistant.ts`, `holidays.ts`).
- **Chores (`lib/chores/`):** table `chores` (`lib/db/schema/chores.ts`): title, note, assigned to
  one account (`assignee_user_id`) or person (`assignee_person_id`) of the family or nobody, `day`
  (the due day / a series' first), `time` ("HH:MM" or null), `part` (morning | day | evening; a
  time decides it: <12 morning, <17 day), `rrule` (null = once; events' `lib/calendar/rrule.ts`),
  `done_at` / `done_by_id` (single chores); `chore_completions` (a repeating chore's ticked
  occurrences), `chore_subscribers` (who gets its notification), `chore_notified` (occurrences
  notified). `chores.ts` (CRUD, `nextDue`, `choreAgenda`), `routes.ts` `handleChores` (`GET/POST
  /chores?today=`, `GET /chores/agenda?from=&to=&today=` (by day, items by part then time, plus
  the open single chores before today as `overdue`; ≤ 62 days), `GET/PATCH/DELETE /chores/{id}`,
  `POST /chores/{id}/done {done, day}` (day: the occurrence of a repeating one), `POST
  /chores/{id}/subscribe {subscribed}`; members read and subscribe themselves, editors change
  (`subscriberIds`, default the creator), viewers may tick off their own; POST takes an optional
  `id` so the assistant's undo brings a chore back under its id). `notify.ts`
  `choreNotifications` (worker, every tick): an occurrence due (its time, else 07:00 / 12:00 /
  18:00 by part, server-local) within the last 3 h, not done, not notified → push to its
  subscribers' app devices only (`notifyFamily` with `channelIds: []`), path
  `/f/{id}/chores/{choreId}?day=`. Accepting a person's invite moves their chores to the account;
  removing a member unassigns theirs and drops their subscriptions. Assistant tools
  `tools/chores.ts` (`get_chores`, `add_chore`, `update_chore`, `remove_chore`, `set_chore_done`);
  search kind `chore`.
- **Knowledge base (`lib/knowledge/`, phase 12):** a derived index of the family's paperwork
  folder (an iCloud Drive folder the app reads; the server never holds a file). Tables
  (`lib/db/schema/knowledge.ts`): `kb_folders` (one per family; its id goes into the folder's
  marker file), `kb_documents` (folder + `path` unique: NFC, "/"-separated, no hidden or ".."
  parts; `name`, `tags` JSON, `size`, `mtime` ms, `hash` SHA-256, `pages`, `text` the uploaded
  pages as JSON, `status` pending | ready | failed | missing | excluded, `error`, the card
  `summary` / `facts` / `doc_date` / `person_*` (invite acceptance and member removal handle it as
  chores' assignee) / `card_status` pending | ready | failed | none / `card_error`, `indexed_at`,
  `missing_since`, the worker's leases `run_token` / `run_until` / `attempts` and `card_run_token`
  / `card_run_until` / `card_attempts` / `card_retries`), `kb_chunks` (integer id = FTS rowid and the source ref `k:<id>`, `seq`, `page`,
  `text`) with `kb_chunks_fts` (FTS5, external content, `unicode61 remove_diacritics 2`, kept in
  step by triggers: hand-written SQL at the end of `drizzle/0025_knowledge.sql`). `routes.ts`
  `handleKnowledge`, **editors only: viewers get 404 on every path** (as an unknown one): `GET/POST
  /knowledge/folder` (created on first use; `{replace: true}`: a new id, the old folder's documents
  deleted; `last_manifest_at` / `_device`: the last non-empty manifest, the device name cut to 100),
  `GET /knowledge/status` (folder, `counts` by status, `chunks`, `cards`: the family's AI set up and
  the assistant on), `POST
  /knowledge/manifest {folderId, device?, files: [{path, size, mtime, hash | null, tags}]}` → `{upload: [path]}`, `PUT /knowledge/documents {folderId, path,
  hash, size, mtime, tags, pages}` → 202 `{id, status}` (≤ 2000 pages, ≤ 2 MB of text, else 413),
  `GET /knowledge/documents?q=&tag=&folder=&person=&status=&cursor=&limit=` (newest `mtime` first,
  excluded ones only with `status=excluded`; DTOs carry `cardStatus`), `GET /knowledge/documents/{id}`
  (card: `facts` `[{text, quote, chunkId, page}]`, `chunks`), `POST …/{id}/card` (202: the card
  made again; 409 unless ready with text; DTOs carry `cardError` when failed), `POST
  …/{id}/reindex`, `POST …/{id}/exclude {excluded}`, `GET /knowledge/tags`. The manifest
  (`manifest.ts`, the device's complete list): same hash → tags / size / time in place; another
  hash → upload; a new path with the hash of a document whose path is gone → that document moves;
  documents not listed → `missing` (an excluded one keeps its status with `missing_since`); `hash:
  null` (not hashed, e.g. not downloaded) → a known path is present (tags only), an unknown one
  ignored, never uploaded or moved; an
  empty manifest changes nothing (a folder the device can't read). An upload with the same hash is
  a no-op (a missing document comes back), unless it brings text to one stored without any; new
  text deletes the chunks and card at once. Status rule (`documents.ts`): ready ⇔ `indexed_at`
  set, failed ⇔ `error`, else pending; a missing document listed again gets its status back from
  that (`restoredStatus`). Whatever makes a document pending again (new text, reindex, un-exclude,
  back from missing) clears the lease and `attempts`. `runner.ts` `KnowledgeRunner` (worker, like
  the `ImportRunner`; `KNOWLEDGE_MAX_CONCURRENT`, 2): claims pending documents by CAS + run token,
  `chunk.ts` `chunkPages` (about 1 000 characters at paragraph / line / sentence boundaries, at
  most 1 500, never across pages), writes chunks + ready (or failed) in one immediate transaction
  that checks the token; a lost run runs once more, then is failed. New chunks (and new text,
  reindex, un-exclude: `CARD_RESET`) empty the card, `card_status` pending (none without chunks).
  `card-runner.ts` `KnowledgeCardRunner` (same pattern, `KNOWLEDGE_CARD_CONCURRENT`, 1; off without
  the assistant) claims ready documents with a pending card only of families whose AI is set up
  (the others wait), round-robin: one per family at a time, the family with the oldest waiting
  document first; it runs `card.ts` `makeCard` (one completion with `familyModel`, the family's
  language and `familyNames`; name, path, tags and the text by page "[Page n]", cut at 30 000
  characters, between `<document>` delimiters escaped inside, the prompt saying it is data; zod-checked
  JSON summary / date / person / ≤ 12 facts; `findQuote`: each quote ≥ 3 words and ≥ 15 characters,
  at word boundaries, in a chunk or across two consecutive ones (NFC, whitespace runs, case,
  typographic quotes ignored); a quote under ¼ of its fact and under 25 characters is a scrap;
  dropped facts are logged; the stored quote is the document's wording); the write checks status
  ready, same hash / `indexed_at` and its card token. Failures → `card_status` failed +
  `card_error`; temporary ones (`TemporaryCardError`: `UpstreamError` 408 / 429 / 5xx, timeouts,
  network) wait 5 min / 30 min / 2 h (`card_run_until` without token = not before, `card_retries`),
  the 5th fails. Saving the AI settings (`PUT /ai/settings`) resets the family's failed cards
  (`retryFailedCards`). The mock AI answers the card prompt from "Date: / For: / Fact: / Shout: /
  Invent:" lines.
  Read-then-write transactions
  here are `{ behavior: "immediate" }` (WAL with the worker writing). `search.ts`
  `searchKnowledge(db, familyId, query, {limit, tags, folder})`: each word a quoted prefix term,
  all words, else any, bm25 order, chunks of ready and pending (a reindex keeps them findable)
  documents → `{chunkId, documentId, name, path, page, text, snippet}`. `cleanup.ts` deletes
  documents gone for 30 days. `sources.ts`: `knowledgeForUser` (who gets the assistant's
  knowledge tools), `chunkSources` (the cited chunks with their card facts) and `excerptOf` (see
  Assistant). The
  family search (`searchFamily`, `knowledge: true` for editors) has the kind `knowledge`: documents
  (not excluded) by name, folder, tags and their best FTS passage (one per document, `page`,
  `snippet` without the `**` marks), every word required as for the other kinds.
- **Connections between modules (phase 7):**
  - *Appointments → Calendar:* `cal_events` (`lib/db/schema/connections.ts`): events from
    `day` to `end_day` (wall-clock `start` on the first / `end` on the last "HH:MM", or null =
    all day), title, location, person, note, url, `source` manual | appointment with
    `source_id` = search, `source_item` = result (the slot's data is copied, results are
    pruned) | apple: imported by the app's Apple Calendar sync, `source_item` = the Apple
    event's key, `externalId` in the API, POST /events with an `externalId` the family has
    answers that event with 200. Repeating: `rrule` (an RFC 5545 RRULE value, `rrule.ts`: own
    parser / bounded expander over plain days, DTSTART always included), `exdates` (JSON), and
    override rows (`series_id` + `occurrence`, the original day) for occurrences changed on
    their own. `lib/calendar/events.ts`: occurrences (`PublicEvent`: `id` is always the
    series', `occurrence` its original day; `GET /events?from=&to=` (a range is required, max 3
    years), lists by day put a multi-day occurrence under each day), the stored form
    (`EventSeries`: `GET /events?raw=1`, `GET /events/{id}`), writes `POST`, `PATCH` /
    `DELETE /events/{id}[?occurrence=&span=this|future]` (none: the whole series; a date shift
    moves exdates and overrides along; `future` splits off a new series). `lib/appointments/booking.ts`
    (`bookSlot` once per slot, optional stop = search disabled; `removeBooking`; app routes in
    `lib/appointments/app-routes.ts`). GET `/families/{id}` adds `events` by day
    (`familyState`). The assistant's tools reach every module (meals, appointments, events
    with `endDate`, `rrule`, `occurrence` / `span`; see Assistant).
  - *Calendar → Meals:* `cal_entry_types.away` (optional `away` in the type API, export and
    import; `TypeRow.away?`). `lib/meals/meal-plan/away.ts` `awayDays`; `populateIteration`
    passes them as `assignSchedule({ skipDates })` and counts cooking sessions from the days
    at home; the plan page shows "Away · Type".
  - *Notifications:* `notification_prefs` (family + event: enabled, `channel_ids` JSON or
    null = all, `state` JSON memory). `lib/notifications/prefs.ts` (`getPrefs`, `setPref`,
    `notifyEvent`; events and defaults in `prefs-shared.ts`; `weekly_digest`: see Week ahead), `daily.ts` (`checkCoverage`
    from `NOTIFY_HOUR`: once a day, only when a gap day wasn't told before; server-local
    days). `notifyRun` skips when `appointment_found`
    is off.
  - *Overview:* `lib/families/dashboard.ts` (`familyDashboard`, `GET /overview`; no searches
    with appointments off).
  - *Week ahead (phase 11):* `lib/digest/`. `checks.ts` `checkSchedule` (pure, thresholds as
    constants): per person over the next 14 days `overlap`, `tight_transfer`, `during_trip`,
    `packed_day`, `long_travel_day`, `travel_week`, `short_night`, `away_clash`,
    `drivers_needed` (children by birthday), `birthday_away`, `unassigned_overlap`; who an event
    is for comes from its `person` text (`attribution.ts` against `familyNames`), travel is an
    estimate (`travel.ts`) over event locations the worker geocodes with Photon into `geo_places`
    (`geo.ts`, at most 25 per family and day, `DIGEST_GEOCODE=0` off; requests read the cache
    only). `digest.ts`: `buildDigest` (`GET /digest?today=`, `routes.ts`; editors hide an issue
    with `POST /digest/dismiss {key}`, `DELETE /digest/dismiss/{key}`, `digest_dismissals`),
    the overview's `weekAhead`, the assistant's `check_schedule` (`tools/schedule.ts`) and the
    `weekly_digest` notification (`weeklyDigests` in the worker on `DIGEST_WEEKDAY` from
    `DIGEST_HOUR`: channels get everything, each account's app only its own issues, the
    children's and unassigned ones). App: `Features/Overview/WeekAhead*.swift` (route
    `.weekAhead`, `/f/{id}/digest`; the sentence per kind is the app's, `WeekAheadText`).
  - *Search:* `lib/families/search.ts` (`searchFamily`, `GET /search?q=&today=&limit=`): recipes,
    events, notes, transactions, appointment searches, people (members + `family_people`) and the
    caller's own chats whose text holds every word (`normalizeForSearch`: case and accents
    ignored), grouped by kind, per kind title matches first then nearest to `today`, `limit` per
    kind (`more` counts the rest); turned-off modules are left out. The app's search tab.
- **Meals (`lib/meals/`, ported from cookless):** recipes, meal plan, cook view, tags. Tables in `lib/db/schema/meals.ts` (re-exported by `schema.ts`): `ingredients`
  and `units` are shared seed data (`lib/meals/seed.ts`, run by `scripts/seed.ts` at every
  server boot and by `npm run db:migrate`; test DBs aren't seeded, tests insert their own),
  everything else belongs to a family (`meal_plans` → `plan_iterations` → entries).
  **No stored shopping list** (phase 10: it lives in the user's Apple Reminders):
  `shopping/needs.ts` (`shoppingNeeds`) computes live what the plan needs per shopping day
  (`computeShoppingSegments` + `aggregateShoppingItems`, leftovers left out), `GET
  /meals/shopping?from=&lang=` → `{days: [{date, items: [{key, ingredientId, name, category,
  quantity, unit}]}]}`; iterations carry `shoppingDates`.
  Pure logic in `lib/meals/domain/` (selection, schedule, aggregation, units,
  scaling), DB work in `recipes/`, `meal-plan/`, `shopping/`, reads in `queries/`; every
  function takes `familyId` and only touches that family's rows (404 otherwise).
  `createFamily` seeds the default `meal_tags`. App routes in `lib/meals/app-routes.ts` and
  `app-routes-plan.ts` (changes need an editor). REST in `http/api.ts`:
  `/api/v1/families/{id}/{recipes,recipes/{id}}` (API token, `lib/meals/route-auth.ts`). Photos: `sharp` → WebP under `MEDIA_ROOT` (`recipes/<id>_<ts>.webp`),
  served by `/api/images/…` to members of the recipe's family only
  (`lib/meals/images/serve.ts`). **AI** (`lib/meals/ai/`, from cookless's `lib/ai`): `prompt.ts`
  (ported), `recipes.ts` (prompt context, tag/unit ids, `generateRecipeImage`), `generate.ts`
  (one chat completion through `lib/assistant/provider.ts` with the family's model —
  `familyModel()` in `lib/assistant/routes.ts` —; photos via `POST {base}/images/generations`
  with `ai_settings.image_model`, or Gemini's native `generateContent` for a Gemini image model
  on Gemini's endpoint), `verify.ts` (zod check of the answer), `import.ts` (one recipe from a
  web page, `POST …/meals/recipes/import`: the browser's text or the page fetched with `net`
  (never private), JSON-LD / og:image read before `htmlToText`, `buildImportPrompt`, saved
  TO_TRY with "Source: <url>" in the description, the photo best effort; nothing is saved once the
  request's signal aborted, i.e. the client went away; with `background: true`, the share
  extension's, it answers 202 at once: `import-queue.ts` saves a `recipe_imports` row (input
  JSON, the starter's language, lease), the worker's `ImportRunner` runs `importRecipe` (claim by
  CAS + run token, at most `IMPORT_MAX_CONCURRENT`, a lost lease runs once more, then failed),
  deletes the row when done and pushes to the starter's devices; failed ones stay for
  `GET /meals/recipes/imports`, `…/imports/{id}/retry`, DELETE, cleanup after 7 days;
  `POST …/import/preview` reads the page without the AI: Recipe JSON-LD or not), `stream.ts` (the NDJSON stream
  of `POST /api/v1/families/{id}/recipes/generate`, inline in the server process: one
  user-started call with timeouts, cancelled with the request), `status.ts` (`mealsAi`: show
  the buttons; off with the assistant). Saving: `recipes/bulk-create.ts`; photo: the meals
  app route `…/generate`.
- **i18n:** `lib/i18n/locales/{en,de}.json` hold only what the server renders: the sign-in
  pages (`getI18n()`, `pages.*`, `auth.*`, `invite.*`, `onboarding.*`) and the notifications
  (`lib/notifications/locale.ts`). Tests check that both files have the same keys and that
  every literal `t("…")` key in `http/` and `lib/` exists. The app has its own strings.
- **Server info and modules (`lib/server-info.ts`):** `GET /api/v1/server` (public) →
  `{ name, version (OHANA_VERSION, else package.json), apiVersion: API_VERSION, modules }`.
  The app requires its `requiredAPIVersion` (apple `Core/Models/ServerInfo.swift`); raise
  `API_VERSION` only for a change an older app can't handle — otherwise the API only grows.
  `DISABLED_MODULES` (finance, meals, appointments, chores, assistant, knowledge; never calendar):
  `moduleEnabled()`; `moduleOfFamilyPath` maps family API paths (finance, meals / recipes,
  appointments, chores, ai / agent, knowledge) for `handleDisabledModules`; the worker, the dashboard's searches, `mealsAi` and the assistant's tools check it.
- **Native app (`apple/`):** SwiftUI, one source tree `apple/Ohana/` for two XcodeGen targets
  (`Ohana` iOS 26, `Ohana-macOS` macOS 26; `project.yml`, the `.xcodeproj` is generated and not
  committed: `cd apple && xcodegen generate`). Pairing: the app opens `/device/pair?state=…&deviceName=…`
  (`http/pages/routes.tsx`, `lib/auth/device-pairing.ts`) in `ASWebAuthenticationSession`;
  signed out, the page sends the user to `/login?next=…` (`safeNext`: paths of this site only);
  "Connect" creates an API token named "<device> (app)" and redirects to
  `ohana://auth-callback?token=…&state=…`. `DELETE /api/v1/me` deletes the calling API token
  (the app's sign out). The app uses the family API and the other `/api/v1` routes with the
  Bearer token; each module has app routes in
  `lib/<module>/app-routes.ts` (`handle<Module>App`, plus `lib/meals/app-routes-plan.ts`),
  registered in the family API's route list before the module's own routes (which answer 404
  for other paths under their prefix); `POST /api/v1/families` creates a family; the account
  (`/api/v1/me/...`, `lib/auth/app-routes.ts`), the administration (`/api/v1/admin/...`,
  `lib/admin/app-routes.ts`) and invites (`/api/v1/invites/{code}`, `lib/families/invite-routes.ts`)
  share `lib/api/app-router.ts`. Without a server the app shows a read-only demo family:
  `Core/Demo/DemoServer.swift` behind `APIClient(demo:)` answers GETs from the templates
  `Resources/Demo/demo-<path>.json` (`{{day:N}}` etc., handlers in `Demo+<Module>.swift`), the
  account is a viewer, changes get 403; `AppModel.switching` puts `LoadingScreen` over the app
  while it moves between the demo and a server (`ConnectServerView` pairs, `DemoBanner` above
  every module). `/setup`, onboarding and login keep a `next` (`homeFor(user, next)`)
  so first-run pairing ends back on the pairing page. What needs the server's own site
  (adding a passkey, an email change confirmed with a passkey) opens `/account?state=…` the
  same way (`Core/Auth/ServerAccountPage.swift`, callback `ohana://account-callback`). The app
  checks `GET /api/v1/server` when connecting and on refresh (`AppModel.serverInfo`,
  `Phase.outdated`) and hides turned-off modules. In the app:
  `App/AppModel.swift` (server, token in the Keychain, `/api/v1/me`, selected family,
  `FamilyContext`: `FamilyAPI` + `didChange`/`revision` signals between modules),
  `Core/API/APIClient.swift` (errors `{error}` / `{message}` → `APIError`, 401 signs out),
  `Core/API/ResponseCache.swift` (offline: the last answer of each screen's GET kept under
  Caches per server, `api.cached("/meals/plan")` → `CachedGet` `saved()` / `fetch()`;
  `LoadState.run($state, api.cached(…))` shows the copy at once as `.saved(…, updating:)`,
  silently (no sync or save indicators anywhere: only errors show, in the error banner; with nothing
  to show yet `PageLoadingView`, empty for 0.4 s, then a spinner), and
  keeps it while the server can't be reached (`APIError.isUnreachable`: offline, no answer, a
  gateway's 502–504; any other failure goes to the banner, `showUnlessUnreachable`), loading
  again when the connection is back (`reloadsWhenReconnected`); editing waits for the server's
  answer; `AppModel` opens on the saved account and
  families; signing out or a new pairing clears it; `Core/Support/Connectivity.swift`;
  `Core/API/Prefetch.swift` loads the selected family's main screens and the meal plan's
  recipes in the background after launch / a family switch / reconnecting (every 15 min at most,
  not in Low Data Mode) through the screens' own request builders (`OverviewView.request`,
  `FinanceStore.listRequest`, …: keep them shared, or the screen won't find the copy; it keeps
  the raw answers, `CachedGet.refresh()`, without decoding them). **Off the main thread:** the
  app's code is on the main actor by default, so a model the screens load is declared
  `nonisolated struct` (and so is every type it holds, `Sendable`) conforming to
  `OffMainDecodable` (`Core/API/OffMainJSON.swift`): `get` / `send`, `CachedGet.fetch()` and
  `LoadState.run` then decode it off the main thread by themselves, and stores read their copy
  with `await get.savedOffMain()` (re-checking after the await that it's still the one wanted),
  not `saved()`; members that need the main actor go into a `@MainActor extension`. Polling
  stores skip an answer whose bytes are the ones shown (`CalendarStore.load`). Photos:
  `RemoteImage` decodes off the main thread at `maxPixelSize` and keeps the files under the
  server's `ResponseCache` folder (`RemoteImageStore`). Offline
  writes, server wins (a refusal drops the change and reloads): the calendar's queue of entry /
  note ops is kept on disk (`CalendarStore.queueFile`, shown on top of what's loaded)),
  `Shell/` (sidebar-adaptable `TabView` on iPad and Mac; on iPhone no tabs (`Module.onPhone`): one
  page at a time in its own navigation stack, the last one opened (`@AppStorage("phoneModule")`, so
  also after the app was closed), every other page picked on the family page behind it; the pages
  opened are kept, hidden, while another shows (`openedPages`, `shellPageVisible`), so each is
  where it was left, as tabs are (a hidden page still "appears": what polls, the calendar, the
  knowledge base, the recipe imports, also waits for `shellPageVisible` and reloads on coming back); at launch every page is built hidden
  behind the loading screen (`launchLoading`, `prebuildPages`, not the search), for a family opened
  later while the family page is open, and one picked before that is built first, then slid in
  (`AppShell.show`: the page rows leave the slide to it); on iPad and the Mac the launch picks each
  tab once behind it (not the search or the assistant: they take the keyboard), the Mac's toolbar
  hidden meanwhile; the pushed-aside pages are one `.geometryGroup()`, or a page shown while aside skips the slide); settings pinned at the sidebar's foot (`tabViewSidebarBottomBar`; on the Mac, which can't leave a tab out of the sidebar alone and draws nothing for a `.hidden` tab, the tab is hidden only while another page is on screen); family switcher: on iPad and Mac
  a system `Menu` (`FamilyMenu`) at the top of the sidebar, on iPhone and where the tab view has no
  sidebar (a narrow iPad window) a family page behind the page / the tabs as in Mail (`FamilySidebar.swift`:
  `FamilySidebarHost` slides them away, `AppModel.showsFamilySidebar`; the toolbar's back button
  (iPhone) / family button or a swipe from the leading edge, which a UIKit edge pan only takes while a module root is
  on screen, `moduleRootsOnScreen`, so it stays "back" on pushed pages; the family on screen as the
  title's subtitle, every page but the assistant with the one on screen highlighted (Search's ready
  to type), scanning a letter, the settings; the families to switch to with one *Add Family* menu
  (new / join) are in the settings there, `FamilyListSection`), assistant `.inspector` ⌘J (a `.sheet` on
  iPhone, `Module.notPages`: an inspector there breaks the page's navigation bar), toggled by the ✨ toggle at the top
  right of every page (`AssistantToolbarToggle`: tinted while open, breathing while a turn runs):
  module roots get it from `shellToolbar()`, a page pushed onto a module's stack adds
  `.assistantButton()`; on iPhone the pages have none: the *Ask Ohana* bar at the bottom (not under the settings), the
  screen's full width (`.assistantBar`, a glass capsule in a `safeAreaBar`, hidden while the keyboard
  is up; `Features/Assistant/AssistantBar.swift`, one button → `family.ask()`; while a turn runs its
  status and the chat's title) takes its place; the bar and the ✨ count as viewers of the chat (`addViewer`), so a turn is followed
  to its end after the panel closes; and its own
  page, `AppRoute`: `family.open(.recipe(id:))` etc. switches to the module, whose root takes it
  with `family.takeRoute(for:)`; server paths `/f/{id}/…` and `ohana://f/{id}/…` map onto routes;
  the search tab (`Module.search`, `Tab(role: .search)`; on iPhone a page like the others, ⌘K → `family.startSearch()`,
  `Features/Search/`) opens its hits the same way, a transaction as `.financeTransaction`; on the
  Mac it's no sidebar row but a field at the right end of every page's toolbar, `ShellSearchField`
  (added with the ✨ by `.assistantButton()`, `family.searchQuery`; typing shows the search page,
  whose field then takes the keyboard, `searchHandoff`): every toolbar ends the page's items, ✨,
  search; a page's own filter is `.pageSearchable` (on the Mac a field among its items: the
  system's `.searchable` field always goes last)),
  `DesignSystem/` (solid content cards — Liquid Glass only on bars and floating controls —, `.readableWidth()` on every page's list or grouped form (a 760 pt column on wide windows; scroll pages cap their stack with `.frame(maxWidth:)` instead), error banner, `CancelButton`/`discardGuard`; the module sets `newItem`/`moduleMenu` focused values for File ▸ New and its menu; the Mac draws those menus in the menu bar, where views have no `AppModel` / `FamilyContext` in their environment: pass values in, never `@Environment` them there), `Features/<Module>/` (plus `Account/`, `Admin/`).
  On iPhone a page's toolbar stays small (the main action, perhaps a filter, one More menu in
  sections; the assistant is the bar at the bottom): what doesn't fit iOS moves into an overflow menu of its own, with the page's
  More as a submenu, so a full page leaves something out instead (Finance has no search field
  there, only a search button); segmented pickers go under the navigation bar there (`safeAreaBar`, as in
  Meals and Finance), not in it (they can't shrink).
  Drag and drop (iPad, Mac) carries the payloads of `Core/Support/DragItems.swift` (own UTTypes,
  declared in `project.yml`, each naming its family): a recipe or a planned meal onto a day of the
  meal plan (`MealPlanDrop`; the plan's recipe column, `MealPlanRecipeColumn.swift`), a calendar
  event onto another day (`CalendarEventDrag.swift`, `CalendarStore.moveEvent`; the grids' selection
  gestures step aside on an event label).
  Chores (`Features/Chores/`): `ChoresView` shows one day (a day bar under the navigation bar:
  back / forward, date picker, Today) in Morning / Day / Evening sections, Overdue on top on today,
  from `GET /chores` + `GET /chores/agenda` (62-day windows from today − 30, `ChoreAgenda.window`);
  rows tick an occurrence off (`POST …/done`, `day` for repeating ones) and show a bell while the
  caller is subscribed (`…/subscribe`: context menu, leading swipe, editor). Local-first, without sync indicators: `ChoresStore` (one per
  family, `FamilyContext.chores`, shared by the pages and the editor) shows the `ResponseCache`
  copies at once and refreshes silently (appear, active, reconnect, `didChange(.chores)`); changes
  (`ChoreChange`: create with a client-made `id` (a 409 counts as done), update, delete, done,
  subscribe) apply at once (`ChoresSnapshot.apply`; a changed chore's days via
  `RepeatRule.occurrences`, `RepeatRule+Occurrences.swift`, the server's expander ported; days
  outside the loaded windows are worked out from the chores) and wait in a queue in Application
  Support `Ohana/Chores/` (`queueFile`, removed on sign out / pairing) sent in order (after each
  change, at launch / active via `AppModel.sendQueuedChanges`, reconnect); a 4xx drops the change
  and reloads, a network failure retries with backoff. `ChoresAllView` lists every chore by part;
  `ChoreEditor` (saves and closes at once; one *When* picker: a part of day or At a Time,
  `ChoreWhen`, repeat via `RepeatEditing`, Notify: the family's accounts, the signed-in
  user ticked on a new chore; viewers get only "Notify me"). Kept lean: no explanatory footers.
  A chore notification's `/f/{id}/chores/{choreId}?day=` opens that day and highlights it
  (`AppRoute.chore(id:day:)`).
  The shopping list is a Reminders list (`Core/Reminders/`: `RemindersStore` wraps one
  `EKEventStore`; `ShoppingReminders` per server + family on this device, in `UserDefaults`: the
  chosen list and the keys already written). `sync` writes `GET /meals/shopping?from=today` one-way
  into it (`ShoppingReminderPlan`, pure: one reminder per item, due on its shopping day, url
  `ohana://f/{id}/meals/shopping/{date}/{key}?q=&t=` as the marker; quantity changes update a
  reminder only while its title is still Ohana's, items gone from the plan are removed likewise,
  deleted ones don't come back); `ShoppingRemindersUpdates` in `AppShell` syncs on becoming
  active, a family switch and meals changes; set up in `Features/Meals/Reminders/` (Settings →
  Shopping List, the meal plan's More menu). Off in the demo. The assistant's Reminders card
  (`edit_reminders`) applies its ops through `RemindersStore` too. Its Calendar card
  (`edit_apple_calendar`, `Features/Assistant/AssistantAppleCalendar.swift`) applies through
  `Core/Calendar/DeviceCalendarStore.swift` (EventKit behind a protocol; read-only access check,
  the assistant never asks for it); every chat request carries `appleCalendar` next to `reminders`.
  Its Notes card (`edit_knowledge_notes`, `Features/Assistant/AssistantNotes.swift`) writes on
  Apply, without a second dialog, into the linked knowledge folder (`FamilyContext.assistantNotes`):
  coordinated atomic UTF-8 writes, a create never overwrites, an update only while the file's
  SHA-256 is `baseHash` (its Finder tags kept unless new ones are given), each written note queued
  with its text (`KnowledgeIndexer.enqueue`), tags-only changes by a forced folder read.
  Scanning (`Core/Scanning/`): `DocumentCamera` (VisionKit; elsewhere and on the Mac a photo /
  PDF picker whose pages `ScanPages` crops: Vision's document detection + `CIPerspectiveCorrection`),
  text with line boxes read on the device, and `ScanPDF` / `ScanFiling`: any scan (letters and
  receipts) can be saved as a searchable PDF (invisible text layer, Title / Keywords) into the
  folder chosen last (a bookmark in `UserDefaults`, security-scoped on the Mac: entitlement
  `files.bookmarks.app-scope`), with an editable name and tags (Finder / Files tags, the
  `_kMDItemUserTags` xattr). With the family's knowledge folder linked on this device
  (`FamilyContext.scanKnowledge` → `ScanKnowledge`, passed into every `ScanFiling`: letters from
  every entry point and receipts) scans file into its root instead (`ScanFolder.knowledge`, no
  picker, the section shows "Knowledge › <folder>") and are queued with their text per page
  (`KnowledgeIndexer.enqueue`, no second OCR; a scan without text isn't; during a run it's listed
  in that run's manifest and sent after it, a run never swaps its text for a re-read; a folder
  changed while the sheet was open is told in the banner); the server's `GET
  /knowledge/tags` (cached, at most 3 s) joins the existing tags. Letters (`Features/Letters/`): *Scan letter* in the family menu, the
  `ScanLetterIntent` App Shortcut (Spotlight, `LetterScanInbox`) and the assistant's paperclip,
  all through `FamilyContext.scanLetter()` / `ShellLetterScan` → `LetterReviewSheet`; photos and PDFs
  shared to Ohana or opened with it (`CFBundleDocumentTypes`, rank Alternate; `AppModel.open` with a
  file URL → `LetterScanInbox.receive`, files arriving together make one letter, iOS's copy deleted
  once read) skip the scanner and reach the same review as picked pages (`letterScanFlow(shared:)`) (name, date
  and tags suggested by `LetterSuggestions`: Apple's on-device model, else rules; tags only existing ones:
  saved with a scan on this device, or on the files in the folder, `FolderTags`, as neither Finder nor
  Files has an API for its tag list; a family member named in the letter brings the tag of their name or its
  short form, `NameMatch`: "Michi" for Michael; whose letter it is (`person`, not necessarily who scans it) names the file
  "date_Person_Title" with that person's tag; the server's `filing` (from `POST …/ai/letter`, sent the
  existing tags) beats Apple's model, which beats the rules, field by field (`LetterReview.merged`); never over the user's edits). From the shell (assistant on, editor, not the demo) the sheet also sends only the
  text to `POST …/ai/letter` (`LetterFind.swift`) and lists the events, tasks and deadlines found at
  its bottom, ticked, each editable (`LetterItemEditor`); Done saves the PDF, then adds the ticked
  ones with `AssistantSuggestionsApply` (failed ones stay, Done retries them). The paperclip
  attaches the text to the chat instead. The assistant's `suggest_items` card (`AssistantSuggestions.swift`,
  `AssistantSuggestionsCard`) ticks each suggestion; Add creates the events (`POST /events`) and
  the reminders (`RemindersStore`), then answers `…/suggestions`.
  The assistant: `family.ask(prompt, send:, newChat:, attachments:)` opens it ready to type from anywhere (⇧⌘J, the overview's field, the Mac's menu bar item (`MenuBarItem`, an AppKit status item: SwiftUI's `MenuBarExtra` re-sets its icon on every window redraw and crashed the app), the
  `AskOhanaIntent` App Shortcut). The chat (`AssistantChatView`, the same in the panel, the iPhone's
  sheet and the page) has one header everywhere: Chats (the history, pushed; not on the page with its
  list column), the title, New chat, More (Open as a page, Move to …, Copy, settings; it never reads
  `\.dismiss` itself, `AssistantDismissReader` keeps it: on the iPad's page that redrew the chat
  without end). It shows at
  once: the conversation doesn't wait for the settings (only the composer does), a chat being opened
  shows `AssistantChatSkeleton`, a long one draws its last 40 items (`AssistantItemWindow`, "Show
  earlier messages"); new items animate in by count (never per streamed piece; opacity and a small
  offset, nothing scales), not those a chat opens with, and another chat cross-fades
  (`AssistantChatStore.session`). The chat stays still while an answer fits: the last turn (from the
  user's last message on) is at least the chat's visible height (`AssistantTurnLayout`,
  `AssistantChatTurns.swift`), so sending scrolls to the end, which puts the message at the top, and
  the answer grows into the room below; growing past the bottom, the chat follows it while the end
  was in view (scrolled up: "Jump to latest"), and a change of the visible height (keyboard, window)
  keeps the end in view (`AssistantScrollFollow`). Tool calls one
  after the other are one row (`AssistantItemGroups`, `AssistantToolGroupRow`: the running one with a
  spinner, then "Used 3 tools", a tap unfolds them); the activity line has one pulsing symbol and no
  timer. On iOS messages aren't selectable in place (costly to lay out): their menu's *Select Text*
  opens the plain text in a sheet (`AssistantSelectTextSheet`); the Mac selects in place. It opens on a new chat
  (still welcome: examples and the 3 latest chats under "Recent") unless the latest chat runs or was
  active in the last 15 minutes (`restoreLatest`, `reopenWithin`; a chat reopened that way gives way
  to a new one once quiet, unless the user picked one); `preload()` (the shell, at start) decides on
  the list's device copy and loads only that chat. A chat's answers are parsed off the main thread
  before it's shown (`AssistantMarkdownCache.prewarm`: its last 40 visible items, in `open` and
  `fetch`). Few moving parts: the ✨ toggle shows a still dot while a turn runs, the Ask Ohana bar
  reads only `store.turn` (assigned when it changes), streamed text shows every 80 ms and `activity`
  is re-assigned while writing at most once a second (`lastTextAt` has the last piece). Recipes are in Spotlight (`RecipeSpotlight.swift`: every family's,
  after loading the account and after recipe changes; emptied in the demo / with Meals off; a result
  opens `ohana://f/{id}/meals/recipes/{id}`). The recipe list's *Import from Web* sheet
  (`RecipeImportView`, editors, with the meals AI) posts a URL to `…/meals/recipes/import`, then
  offers to open the recipe or undo (DELETE it). The share extension instead first says whether the
  page is a recipe (`Preprocess.js` finds schema.org Recipe JSON-LD in Safari on iOS, else
  `…/import/preview`), asks, then hands the page off (`background: true`, 202) and closes; the
  worker imports it, and the recipe list shows the waiting / failed ones as placeholder cards on
  "Want to try" (`RecipeImports.swift`, polling `GET …/meals/recipes/imports`; a banner on
  Favourites). `SharedPage.combine`: a Safari result without its own URL (a crashed tab) doesn't
  count, the shared URL does. From outside the app: Siri / Shortcuts actions without opening it
  (`App/Intents/CaptureIntents.swift`: add to the shopping list (a reminder in the family's Reminders list), add an event, import a recipe;
  `IntentConnection`) and the *Save to Ohana* Safari share extension (`apple/ShareExtension/`,
  targets `OhanaShare` / `OhanaShare-macOS`, bundle id `de.fa-krug.Ohana.Share`; iOS sends the
  page's text via `Preprocess.js`). Code both use is in `apple/Shared/` (`Keychain`,
  `SharedConnection`): no App Group — the app mirrors the server URL and selected family into the
  shared Keychain access group next to the token, and removes them on sign out.
  Member colors: `DesignSystem/MemberColor.swift` (the server's palette by key, `FamilyAvatar`
  (the member's photo when there is one, `RemoteImage` over the initials), `MemberIcon`: the small
  tinted avatar, `MemberPhoto`: path, the upload as an upright ≤ 2048 px JPEG; on `FamilyMemberPage`
  the big avatar is the control: a tap opens `MemberPhotoCropper` (gestures only: pinch anchored at
  the fingers, drag, rubber-band then settle, double-tap 2×; on the Mac also scroll / ⌘-scroll;
  VoiceOver adjustable; pure math in `MemberPhotoCropGeometry`) on the original, or the library
  first without a photo; choosing another picture or a file and removing are in the editor and the
  avatar's context menu); a member's name as text only where there is room (the
  type editor's member picker, Apple Calendar runs titled "Type (Member)"), elsewhere (type
  chips, settings rows, the overview) the icon only; grid cells are the plain color. The color is
  chosen on `FamilyMemberPage`; a type's member in `CalendarTypeEditor` (changing it or the order
  reloads the types: their shades shift). A type shows as `CalendarTypeBadge`
  (`Features/Calendar/CalendarSymbols.swift`): the member's initials, then its SF Symbol on its
  color (`CalendarRole.defaultIcon` until one is picked in the editor's `CalendarSymbolGrid`); a
  note's icon is an SF Symbol too (`CalendarSymbol.noteIcons`), tinted in the theme color (on a
  type-filled cell the cell's ink). The pickers' symbols, their names and the words (German and
  English, folded) that suggest them are `CalendarSymbol.catalog` (`CalendarSymbolCatalog.swift`);
  `suggestions(for:)` (an emoji in the text first, then keywords: ≥ 5 letters anywhere, shorter at
  a word's start) fills the grid's Suggested row, and a new comment / a renamed type showing its
  role's icon takes the best one until an icon is tapped. Tooltips on touch: `.longPressTip(_:)`
  (`DesignSystem/LongPressTip.swift`, a popover bubble after a long press, `.help` on the Mac;
  not inside a Button: the selection bar's type chips are tap-gesture views for that).
  Calendar events in the app: `CalendarEvent` is an occurrence (list identity `uid` = "id@occurrence"),
  `CalendarEventSeries` the stored form; `RepeatRule` (+`Text`: summaries, the editor's presets)
  parses / writes RRULEs; `CalendarEventEditor` / `CalendarEventRepeatViews` (Apple-like Repeat and End
  Repeat, "this event only / future events"), `CalendarEventRequests` (pure request builders; moving a
  whole series shifts its BYDAY), `CalendarEventText` (how a multi-day event reads on each day);
  `CalendarStore` snapshots the series (`GET /events/{id}`) before a change for undo.
  The wide calendar (iPad, Mac): from `CalendarLayoutRule.sideColumnFrom` the selected days' details
  are a column beside the grid, below it narrower (capped at `detailsMaxWidth`); zoom is in More,
  pinch, ⌘+/−/0 and the Calendar menu (the toolbar: year, Year / Month, Undo, More). The year grid can align weekdays (`CalendarWeekdayAlignment`, 37 columns: every
  consumer finds days through `CalendarGridLayout.Year`); under it `CalendarLegend` lists the year's
  types, a click highlights one (`CalendarStore.highlightedTypes`, other days `Info.dimmed`, Esc
  clears). Days before today are faded, nobody's gray types drawn darker in dark mode
  (`CalendarTypeColor`, `CalendarDayLook`).
  Apple Calendar sync (`Features/Calendar/AppleCalendarSync*.swift`, Settings → Calendar), per device
  and family through EventKit: `AppleSyncPlanner` (pure, tested) plans, `AppleCalendarSync` runs it
  (at launch, foreground, every 15 min, `EKEventStoreChanged`, `FamilyContext.didChange(.events/
  .calendar)`) and keeps the links in Application Support `Ohana/CalendarSync/`. Events both ways
  (Ohana wins a conflict; viewers one way), a repeating event as one series (`RepeatRule` ↔
  `EKRecurrenceRule`, master by `calendarItemIdentifier`) whose occurrences changed or deleted on
  their own sync day by day within the window (`AppleSyncException` per original day; one pass more
  after a series changed as a whole), day entries as all-day runs to Apple only; Ohana's copies
  carry `ohana://f/{id}/calendar/{day}?event=|entry=` as their URL and imports keep their
  `externalId`, so devices sharing an iCloud calendar link instead of copying twice.
  The knowledge base on the device (`Core/Knowledge/`, phase 12; editors, module on, not the demo:
  `FamilyContext.knowledgeAvailable`): `KnowledgeFolder` links the family's folder per server and
  family (a security-scoped bookmark in `UserDefaults`; choosing reads or writes the marker
  `.ohana-knowledge.json`, `KnowledgeLinkDecision`: another family's marker, another folder of the
  family, or a folder another device reads throw `KnowledgeFolderError`, chosen again with
  `accepted`; a server folder another device reads is then replaced, `POST /knowledge/folder
  {replace: true}`, and a device whose manifest / upload gets 404 checks the folder and becomes
  `.replaced`: it stops until a folder is chosen again), `KnowledgeWalker` lists it (hidden files,
  packages, all symbolic links and files over 100 MB skipped; a folder it can't list fails the run,
  nothing sent; NFC paths, Finder tags, iCloud placeholders by their real name),
  `KnowledgeHashCache` (path + size + mtime → SHA-256; size only for a file not on the device; a
  hash whose text failed to read isn't read again) hashes only what changed, a file it can't hash
  is still listed, with its last hash or `hash: null`; iCloud loads files on the Mac as needed, on
  iOS only off Low Data Mode and expensive networks, up to 300 MB a run (`KnowledgeDownloads`), and
  they're evicted again once read, `KnowledgeText` reads the text by page
  (PDFKit, Vision OCR, images, txt / md / rtf / html, `NSAttributedString`'s formats; nil: this
  device can't, another may), `KnowledgeUploadQueue` keeps the uploads on disk (by path; removed by
  path + hash; a refusal drops, an outage waits with backoff; a file changed since it was hashed
  waits for the next run, never a run at once), all in Application Support `Ohana/Knowledge/<server>/<family>/`
  (written off the main actor, in order, nothing after *Change…* / *Remove* / sign out; removed on
  sign out / pairing and by *Remove from This Device*). `KnowledgeIndexer` (one per
  family, `FamilyContext.knowledge`, observable `phase` / `lastRun` / `unreadable` / `waiting`)
  walks, hashes, sends the manifest (with the device's name), then reads and uploads what the
  server asks for; one run at a time. Triggers: `AppModel.indexKnowledge()` at launch, on becoming
  active, on reconnecting and every 15 min on the Mac (each family at most every 5 min),
  `FamilyContext.indexKnowledge(force:)` for *Read Now*, `enqueue(file:pages:)` for a scan with its
  text (see Scanning). Settings → Knowledge (`Features/Knowledge/KnowledgeSettingsView.swift`, `.settings(.knowledge)`):
  the folder (`.fileImporter`, the conflict as an alert offering to use it anyway), the index
  (`GET /knowledge/status` through `api.cached`, with the indexer's progress, waiting and unreadable
  files, the last manifest's time and device), *Read Now*.
  The knowledge base page (`Module.knowledge`, ⌘9; shown where `FamilyContext.isEnabled(.knowledge)` /
  `AppModel.isEnabled` say `knowledgeAvailable`, `ServerInfo.isEnabled` only says the server has it;
  the demo hides it for now): `Features/Knowledge/KnowledgeView.swift`, `GET /knowledge/documents`
  (`KnowledgeDocumentQuery`: a tag (from `/knowledge/tags` with counts: a list in a column beside the documents from `tagColumnFrom`, narrower one menu chip), a folder (subfolders of the paths
  seen), a person (`/household`'s members), *Show Left Out* = `status=excluded`; `nextCursor` pages;
  no search field of its own: documents are found by the search page), a list in a 680 pt column
  (`KnowledgeView.columnWidth`, the filter chips' bar as wide), rows with the name, whose it is
  (`MemberIcon`) and the date (`docDate`, else the file's), the folder, two lines of the summary
  (marked with a sparkle: the assistant's), tags and a badge unless ready; empty: no folder on this device nor on the server → Settings → Knowledge, else
  "Nothing read yet". Another query starts from `.idle` (never the last one's documents under it),
  answers for an older query are dropped; a refresh asks for as many as are loaded (≤ 200,
  `KnowledgeDocumentsPage.refreshed`), so it keeps the pages; it reloads on becoming active, after the
  indexer's runs and on `didChange(.knowledge)` (with status, tags, members), and polls every 15 s
  (documents only, while active) while something shown waits for the worker. `KnowledgeDocumentView`: path as a breadcrumb, date, person, tags, its
  status (failed: `error`; "Summary is being written" while `/knowledge/status` `cards`; a failed
  card: `cardError` quietly and *Write Summary Again*, `POST …/{id}/card`), summary and facts
  ("Summary" with sparkles, "By the assistant"; each fact keeps its quote and page) (a tap opens the original at the fact's page and quote), the text by page (collapsed;
  a route's page open, its quote marked); *Open Original*, More: *Show in Finder* (Mac), *Read
  Again*, *Leave Out* (confirmed) / *Include Again*. Routes `AppRoute.knowledgeDocument(id:page:quote:)`,
  `/f/{id}/knowledge[/{documentId}[?page=]]`; links in the assistant's answers and tool results keep
  their query (`AppRoute.parse(url:)` / `parse(link:)`). *Open original* (`Core/Knowledge/KnowledgeOriginal.swift`,
  `Features/Knowledge/KnowledgeOriginalView.swift`: `KnowledgeOriginalOpener` + `.knowledgeOriginal(_:)`):
  the folder's bookmark + the path (`locate`: each part compared NFC, an iCloud placeholder by its
  real name), copied coordinated (iCloud loads it; `KnowledgeOriginalLoader`, off the main actor: the copy
  blocks a GCD thread of its own, and Cancel and a 120 s timeout end the wait whether or not
  `NSFileCoordinator.cancel()` frees it (a late copy is deleted); a file not on the device fails at
  once while offline) into the temporary directory within the security scope, the copy deleted when the
  viewer closes (and `KnowledgeOriginals` swept at launch); a PDF in PDFKit at the page with the quote marked
  (found off the main actor before the viewer opens, `KnowledgePDFHighlight.locate`; `KnowledgeQuoteMatch`: the words in order, whitespace, case, accents and punctuation ignored, else
  its first 8, 5, 3 words; on its page, then the pages beside it), anything else in Quick Look; no
  folder here (or missing, replaced) → an alert offering Settings → Knowledge.
  Sources in the assistant (`Features/Assistant/AssistantSources.swift`): an answer item's `sources`
  (`AssistantItem.assistant(text:sources:)`) turn its `[[k:<n>]]` markers into chips "[1]" (numbered
  by the sources' order; `AssistantSourceMarkers`: placeholders through the Markdown, then links
  `ohana-source://n`; markers without a source and one still streaming at the end hidden) with a
  "Sources" list below; a tap shows `AssistantSourceSheet` (the quote with its `excerpt` marked and
  scrolled to; *Open Original* at the page and *Show in Knowledge Base* mark the excerpt, else the
  quote's first words, `AssistantSourceExcerpt`; a 404 is the document gone, or no access when
  `/knowledge/status` is refused too, `AssistantSourceAvailability`). The search tab's `knowledge` hits open the document at their `page`.
  The cook view (`MealsCookView`) turns durations in a step's
  text into timer links (`StepDurations`, English and German); `CookTimers` (app-wide, kept in
  `UserDefaults`) schedules a time-sensitive local notification per timer (shown in the
  foreground too: the notification center's delegate is `PushNotifications`) and keeps one Live Activity for all running
  timers (iOS: `apple/Shared/CookTimerAttributes.swift`, drawn by the widget extension
  `apple/OhanaWidgets/`, the XcodeGen target `OhanaWidgets` embedded in `Ohana`). The same
  extension has the Home Screen / Lock Screen widgets (also `OhanaWidgets-macOS`, desktop widgets
  in the Mac app, without the Live Activity; one bundle id `de.fa-krug.Ohana.Widgets`; both
  nonisolated by default and compiling `Shared/`, `Core/Widgets/WidgetFeed.swift`,
  `Core/Support/Day.swift`, `DesignSystem/Tints.swift` and `Localizable.xcstrings`): Today,
  Tomorrow, Tonight's dinner, Appointment found (Lock Screen families on iOS only).
  They show the family the app shows: the extension reads `SharedConnection` (no App Group
  either), loads `GET /families/{id}/overview?today=` into a `WidgetSnapshot` and keeps the last
  one in its own container for when the server can't be reached (`WidgetStore`; the modules the
  server has off are a Keychain item the app writes). `App/WidgetSync.swift`: `AppModel` writes
  those modules and reloads the widgets after loading the account, on a family switch and on
  sign out, `FamilyContext.didChange` (debounced 3 s) and the background reload them too;
  timelines every 30 min plus each of today's event ends and midnight. Taps open `ohana://f/{id}/…`
  (`/calendar/{YYYY-MM-DD}` is a day of the calendar in `AppRoute.parse`). German strings: per-module
  `apple/Localization/*.de.json`, merged into `Resources/Localizable.xcstrings` by
  `apple/scripts/merge-localizations.py` (`--check` in CI). Build/test: `apple/README.md`; CI:
  `.github/workflows/apple.yml` (macOS unit tests, iOS build, strings; only on `apple/**` changes).
  Release: App Store Connect / TestFlight, one bundle id `de.fa-krug.Ohana` for both platforms;
  built and uploaded by Xcode Cloud (`apple/ci_scripts/ci_post_clone.sh` runs XcodeGen); version
  from `MARKETING_VERSION` (the plists say `$(MARKETING_VERSION)`), build numbers Xcode Cloud's;
  `Resources/PrivacyInfo.xcprivacy` declares the `UserDefaults` use. Steps in `apple/README.md` → Releasing.
  Keeping the Mac smooth while the assistant panel slides (each step lays out the whole window):
  the panel stays in the inspector while closed (`AssistantPanel(visible:)`: closed, no toolbar
  items, no ask requests, not a viewer of the chat) and has its buttons in a header of its own,
  not in the toolbar; every page (`AppShell`) and the panel take any size
  (`.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)`), so the window
  doesn't measure them for its smallest size — never a frame or a custom `Layout` around the tab
  view itself (that lays out without end); no `ViewThatFits` in a toolbar; no width in a page's
  state where a flag will do; the calendar's year grid is one `Canvas` (`CalendarYearDays`).

## Conventions

- **Always consider the assistant** for every new feature and every schema change: can it read
  the new data and act on it (its tools in `lib/assistant/tools/`, their filters and result
  columns, the system prompt in `chat.ts`), do its changes return undo steps, and are viewers
  and `allow_writes: false` still limited to the reading tools? A feature the user can't ask the
  assistant about is unfinished.
- Tests use an in-memory database with all migrations (`lib/test/db.ts`), factories in
  `lib/test/factories.ts` (appointments: `lib/test/appointments.ts`), fixtures in
  `tests/fixtures/`, and a software passkey (`lib/test/authenticator.ts`) so WebAuthn flows
  run against the real verification. Nothing in tests touches the network (fake clients,
  injected `send` / sources).
- Keep env names clear of Vite/Vitest's: the public URL is `APP_URL` (Vitest sets `BASE_URL`).
- Deploy: every push to `main` is a release: CI publishes `ghcr.io/fa-krug/ohana:latest`
  (+ `:main`, `:sha-<7>`) and redeploys fa-krug's server; no release tags (see the `deploy`
  skill and docs/self-hosting.md). `version` in `server/package.json` is only bumped for a
  notable change; the image reports `<version>+<commit>`.
