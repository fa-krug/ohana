# Ohana: plan

**Ohana** is one app for the whole family. It replaces three apps:

| Today                                           | Becomes in Ohana                    |
| ----------------------------------------------- | ----------------------------------- |
| `family-planner` (vacation calendar, finance, AI) | **Calendar**, **Finance**, **Assistant** |
| `cookless` (recipes, meal plan, shopping, cook) | **Meals**                           |
| `findmyappointment` (Doctolib / jameda watcher) | **Appointments**                    |

The family signs in once, shares one family, one AI setup, one set of notification channels,
and one installed PWA. The modules know about each other (see
[Connections](#connections-between-modules)).

## Decisions

| Topic           | Decision                                                                                                                                                       |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Name / repo     | **Ohana**, repo `fa-krug/ohana` (the app at the repo root), `ohana.fa-krug.de`                                                                                 |
| Approach        | A **new app**, taking the best parts of the three; the old apps run on until their data has moved                                                              |
| Hosting         | **Raspberry Pi**, one Docker image, Traefik on the `gitops_default` network, redeployed by CI through Arcane (GitHub OIDC), like cookless and findmyappointment |
| Database        | **SQLite** (`better-sqlite3`, WAL) with **Drizzle**; one file under `/app/data`, plus `/app/data/media` for images                                             |
| Framework       | **Next.js 16** (App Router), React 19, TypeScript, Tailwind 4, Radix / shadcn-style `components/ui`                                                            |
| Processes       | **web** (Next.js) and **worker** (scheduler, AI turns, notifications): the same image, two entrypoints, so a hanging scrape never blocks the UI                 |
| Existing data   | **Imported**: users, families, calendars, finances, recipes, meal plans, searches. Accounts merged by email                                                    |
| Old apps        | Shut down after the import; their domains are **not redirected** but removed. The Supabase project stays **read-only** for a while as an extra backup          |
| Roles           | **Admin** (manages users) + per family **editor / viewer** (from family-planner). cookless / findmyappointment OWNER and MEMBER both become editor             |
| Joining         | Admin **setup links** (family-planner) _and_ **invite codes** (cookless)                                                                                       |
| AI              | Any **OpenAI-compatible** model, per family (family-planner). cookless's Gemini key moves over via Gemini's OpenAI-compatible endpoint                          |
| Notifications   | findmyappointment's channels (Pushbullet, Pushover, Telegram, email) become **family-wide**, usable by every module                                             |
| Languages       | English and German (cookless i18n: dictionaries + provider, with tests)                                                                                        |
| Tests           | Vitest; the domain tests of all three apps move along with their code                                                                                          |

## What comes from where

| Area                                  | Source                                                       | Notes                                                                                                                                                                |
| ------------------------------------- | ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Project setup, Docker, CI, deploy     | cookless `web/`                                              | Add the worker entrypoint; backups (see [Deployment](#deployment))                                                                                                   |
| Passkeys, passwords, cookies          | cookless `lib/auth/` (identical in findmyappointment)        | Plus findmyappointment's `email.ts` and `reauth.ts`                                                                                                                  |
| Tokens: sessions, API tokens, setup links | family-planner `_shared/auth.ts`                         | One `auth_tokens` table storing only SHA-256 hashes; kinds `session`, `api`, `setup`. API tokens let scripts and AI agents use the REST API                          |
| Admin (users, families)               | family-planner `admin.ts`, `AdminPage`                       |                                                                                                                                                                      |
| Families, members, roles              | family-planner `families.ts`                                 | Invite codes from cookless `lib/households/invites.ts`                                                                                                               |
| Calendar (year grid, types per year, coverage, notes, ICS feed) | family-planner `vacation.ts`, `ics.ts`, `features/vacation` | The UI is a Vite SPA today; components move into App Router pages, client-side                                                                     |
| Finance                               | family-planner `finance.ts`, `category_tree.ts`, `features/finance`, CSV import | The largest module (~1,800 lines of domain logic)                                                                                                 |
| Assistant (chats, tools, undo, web search, analytics, calc, auto-categorize) | family-planner `_shared/ai/`, `agent.ts`, `features/chat` | Runs in the worker; the hand-off between Edge Function invocations is no longer needed, the lease (`run_token`) stays so a restart resumes a turn |
| Recipes, meal plan, shopping, cook view, offline queue | cookless `lib/recipes`, `meal-plan`, `shopping`, `cooking`, `offline` | Recipe generation and images: from the cookless Gemini code, behind the family's AI settings                                                    |
| Appointments (Doctolib, jameda, scheduler, slot detail, distance) | findmyappointment `lib/doctolib`, `jameda`, `searches`, `sources` | Home address becomes a family setting                                                                                                  |
| Notification channels                 | findmyappointment `notifications.ts`                         |                                                                                                                                                                      |

### Porting family-planner's backend

family-planner's API already runs against a `Store` interface (`_shared/store.ts`), with a Supabase
and an in-memory implementation. Ohana adds a **Drizzle/SQLite implementation of that interface**,
so `vacation.ts`, `finance.ts`, `families.ts` and `ai/*` move over with little change, and their
Deno tests become Vitest tests running against the in-memory store. The HTTP routing in
`handler.ts` becomes Next.js route handlers under `app/api/`, keeping the same paths and JSON
shapes, so the SPA components and API-token scripts keep working.

## Architecture

```
ohana/  (the repo root)
├─ app/
│  ├─ (auth)/            sign-in, setup link, onboarding
│  ├─ (app)/f/[familyId]/
│  │  ├─ calendar/       year grid, settings → Calendar
│  │  ├─ finance/        transactions, overview, comparison, import
│  │  ├─ meals/          recipes, plan, shopping, cook
│  │  ├─ appointments/   searches, runs, slot detail
│  │  └─ settings/       general, members, sharing/feed, AI, notifications, data
│  ├─ (account)/         profile, passkeys, password, API tokens
│  ├─ admin/             users, families
│  └─ api/               REST (also for API tokens), calendar.ics, health
├─ lib/
│  ├─ db/                schema.ts (one file per module, re-exported), client, store
│  ├─ auth/  families/  notifications/  i18n/  offline/
│  ├─ calendar/  finance/  meals/  appointments/
│  └─ assistant/         chats, tools (one tool file per module), provider, analytics, calc
├─ worker/               scheduler loop: appointment searches, assistant turns, cleanup
├─ drizzle/              migrations
└─ scripts/              db-migrate, seed, import-legacy, set-password
```

- **Layout:** family-planner's: left sidebar with the family switcher and the modules (Calendar,
  Finance, Meals, Appointments), Settings at the bottom; right sidebar ✨ for the assistant
  (`Ctrl/⌘+J`); sheets on phones.
- **Module switch:** a family can turn modules off (settings → General), e.g. a family that only
  uses Meals.
- **Worker:** one loop (like findmyappointment's `instrumentation.ts` scheduler, but in its own
  process). It claims due work through the database (`next_run_at`, chat `run_token` leases), so
  a crash or redeploy loses nothing.

## Data model

All tables are scoped to a family (`family_id`) unless they belong to an account. Ids are text
UUIDs; money is integer cents; days are ISO `YYYY-MM-DD` text; timestamps are integers.

| Group        | Tables                                                                                                                                                   |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Accounts     | `users` (email, name, password hash, is_admin, language, onboarding step, last family), `auth_tokens`, `passkey_credentials`, `rate_limits` (WebAuthn challenges live in a signed cookie) |
| Families     | `families` (name, feed_id, legacy_id, language, currency, home address + lat/lng, enabled modules), `family_members` (role), `invites`                 |
| Shared       | `ai_settings` (base URL, model, encrypted keys, search provider, image model), `notification_channels`                                                  |
| Calendar     | `cal_entry_types` (per year), `cal_entries`, `cal_notes`                                                                                                 |
| Finance      | `fin_settings`, `fin_categories` (tree), `fin_accounts`, `fin_transactions` (transfer_id, split_of, import_hash), `fin_csv_mappings`, `fin_benchmark` |
| Assistant    | `chats`, `chat_items`, `chat_messages`                                                                                                                   |
| Meals        | `ingredients`, `units` (shared seed data), `meal_tags`, `recipes`, `recipe_ingredients`, `cooking_steps`, `step_ingredients`, `recipe_tags`, `meal_plans`, `plan_iterations`, `meal_plan_entries`, `meal_plan_excluded_tags`, `shopping_lists`, `shopping_list_items` |
| Appointments | `appt_searches`, `appt_search_channels`, `appt_ignored`, `appt_runs`, `appt_results`, `appt_profile_cache`                                              |

## Accounts and sign-in

- **Passwords:** argon2id (cookless). family-planner's `pbkdf2-sha256$…` hashes are still
  accepted and re-hashed to argon2id at the next sign-in.
- **Passkeys don't move.** A passkey is bound to the domain it was made for (`cookless.fa-krug.de`,
  `fma.fa-krug.de`, `family-planner.fa-krug.de`), and Ohana has its own. Everyone adds a passkey
  on first sign-in to Ohana. Accounts without a password (passkey only) get a **setup link** from
  the admin.
- **First run:** `/setup` creates the first account (password or passkey), which becomes the
  administrator; it's only open while there are no users (no default `admin` / `admin`). The
  import brings the existing accounts instead.
- **Tokens:** sessions, API tokens and setup links are one table, `auth_tokens`, holding only
  the SHA-256 of each token (as family-planner does), so family-planner's API tokens can be
  imported as they are.

## Connections between modules

The reason for one app instead of three; built after the modules are in place:

1. **Appointments → Calendar:** a slot marked as booked becomes a calendar entry (and appears in
   the ICS feed, optionally).
2. **Calendar → Meals:** the meal plan skips days on which the whole family is away (types with
   the role _Covers_ / _Day off_ for everyone, or a "Away" type).
3. **Meals → Finance:** the shopping list's estimated cost; grocery transactions are linked to the
   shopping trip of that day.
4. **Assistant everywhere:** tools for recipes and meal plans ("plan next week without fish"),
   appointment searches ("find a dermatologist before June"), next to the calendar and finance tools.
5. **Notifications everywhere:** appointment found, assistant turn finished, import done,
   uncovered day-care closure in the next two weeks.

## Importing the existing data

A script `scripts/import-legacy.ts` reads the three old databases and writes them into an
empty Ohana database. It has a **dry run** that only reports what it would do.

| Source            | How it's read                                                                                           |
| ----------------- | ------------------------------------------------------------------------------------------------------- |
| cookless          | its SQLite file (copied from the Pi volume) + the `media/` folder                                       |
| findmyappointment | its SQLite file (copied from the Pi volume)                                                             |
| family-planner    | `pg_dump --data-only` of the Supabase `public` schema (or a direct connection string), parsed by table |

- **Users** are merged by lowercased email; the name comes from family-planner, `is_admin` from
  family-planner or cookless/findmyappointment `is_staff`.
- **Families:** a mapping file (`import-map.json`) says which cookless household and which
  findmyappointment household belong to which family-planner family (the Krug family exists in all
  three). Unmapped ones become families of their own. Members and roles are combined: editor wins
  over viewer.
- **AI settings:** family-planner's are kept; a cookless Gemini key without family-planner settings
  becomes base URL `https://generativelanguage.googleapis.com/v1beta/openai/` with that key.
  The secrets are decrypted with the old key and encrypted with Ohana's.
- **Appointments:** searches, channels and ignore list move; run history and results don't
  (disposable, as in findmyappointment's own Django import).
- **Calendar feeds** keep their `feed_id` / `legacy_id`, but their URLs change host with the
  old apps gone: subscriptions (e.g. in iCloud) are made again from Ohana's feed settings.

## Deployment

- One multi-arch image (`linux/amd64`, `linux/arm64`) on Docker Hub, built by CI on `main`;
  Arcane project `ohana` redeployed through GitHub OIDC, then `/api/health` is awaited.
- `docker-compose.production.yml`: services `web` and `worker` from the same image, one volume
  `/app/data`, Traefik labels for `ohana.fa-krug.de`, network `gitops_default`.
- Migrations run at boot in `web` (as in cookless); `worker` waits for them.
- **Backups:** the finances move from Supabase's cloud to the Pi, so the worker writes a
  nightly SQLite backup to `/app/data/backups` (14 kept), and a job on the Pi copies it off-site
  (e.g. restic to a cloud bucket); the README documents both and the restore.
- Environment: `AUTH_SECRET`, `APP_URL`, `DATABASE_FILE`, `WEBAUTHN_RP_ID`, `WEBAUTHN_RP_NAME`,
  `WEBAUTHN_ORIGIN`, `BACKUP_DIR` / `BACKUP_KEEP` / `BACKUP_HOUR`, `PORT`, `MEDIA_ROOT` (recipe
  images, phase 4), optionally `ENCRYPTION_KEY` (channel and AI secrets; derived from
  `AUTH_SECRET` when unset, phase 5), the worker's `APPT_*` settings (see `.env.example`).

## Phases

| #  | Phase              | Delivers                                                                                                                                   |
| -- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| 0  | Foundation ✅      | Repo, Next.js app, schema for accounts + families, auth (passkeys, passwords, tokens, setup links, invites), admin, layout with sidebars, i18n, CI, deploy, backups |
| 1  | Calendar ✅        | Store implementation over Drizzle, year grid + mobile months, types per year, coverage, notes, ICS feed                                    |
| 2  | Finance ✅         | Transactions, accounts, category tree, transfers, splits, CSV import, overview, comparison, benchmark                                      |
| 3  | Assistant          | Chats in the worker, calendar + finance tools, web search, analytics, calc, auto-categorize                                                |
| 4  | Meals ✅           | Recipes, meal plan, shopping list, cook view, offline queue ✅ — recipe generation and assistant tools for meals follow after the assistant (phase 3) |
| 5  | Appointments ✅    | Doctolib + jameda searches, worker scheduling, slot detail, notification channels; assistant tools for appointments                        |
| 6  | Import + cut-over  | `import-legacy.ts` with dry run, a rehearsal on a copy, then the real import; old apps shut down, Supabase set read-only, old repos archived |
| 7  | Connections        | The cross-module features above                                                                                                           |

### Notes on phase 5

- Built ahead of phases 1–4. The **assistant tools for appointments** wait for the assistant
  (phase 3); `lib/appointments/*` is ready for them. The calendar connection is phase 7.
- Scheduling is the worker's: due searches are claimed through the database (`next_run_at`,
  a lease `locked_until`, `run_requested_at` for "Run now"), so two workers never run one
  search; the web process has no scheduler (findmyappointment's `instrumentation.ts` and
  `/api/cron/tick` are gone). Every outbound request has a 30 s timeout (the source had none).
- Notification channels are family-wide (`notification_channels`, `lib/notifications`,
  `notifyFamily`) with tokens sealed by `lib/secrets.ts` (`ENCRYPTION_KEY`, else derived from
  `AUTH_SECRET`). Families have no language yet: notifications use the language of the
  family's longest-standing editor.
- The home address is `families.home_address` / `home_lat` / `home_lng` (real numbers, null
  when unset) instead of findmyappointment's text columns.
- Searches are edited on their own page rather than in a modal (as findmyappointment's code
  does); the list shows the three earliest doctors per search inline.

### Phase 4 notes (deviations from cookless)

- **Recipe generation and AI photos are not ported yet**: they need the family's AI settings
  (phase 3). The generate buttons are gone; cookless's `bulk-create` (only used by the
  generator) and `lib/ai` come back with them, behind the family's OpenAI-compatible model.
- **Family-scoped everywhere:** cookless's "active household" is the `[familyId]` in the URL;
  viewers see everything (and can cook) but can't change anything (server: `requireRole`).
- cookless's `tags` table is `meal_tags`; the meals migration gives families that already
  existed the default tags (new families get them from `createFamily`).
- **Photos are no longer public:** `/api/images/...` answers only members of the recipe's
  family (cookless served them to anyone with the URL) and is cached `private`. Uploads go
  through a server action with a 6 MB body limit (cookless kept Next's 1 MB default, so most
  phone photos failed).
- **Shopping ticks are idempotent** (`{ kind: "set", checked }` instead of a toggle): with a
  toggle, a request that reached the server but whose answer was lost (e.g. a reload right
  after a tick) was queued offline and replayed, unticking the item again. The queue also
  drops ops the server refuses for good (4xx other than 401/429) instead of blocking on them
  forever. The sync route is `POST /api/v1/families/{id}/shopping/toggle` (`toggle` stays
  accepted).
- Small fixes found while porting: the ingredient suggestions stayed open after picking one;
  empty prep/cooking times (and program parameters) were saved as 0; a dnd-kit hydration
  mismatch in the step editor.
- The cookless welcome page is the meals entry page while a family has no recipes; the tag
  settings are a *Tags* tab of the module. The PWA install banner stays out (an Ohana-wide
  concern, later).

Each phase ends deployed and usable. The old apps stay live until phase 6, so nothing is lost
while Ohana grows.

### Phase 2 notes (deviations)

- The finance part of family-planner's `Store` is `lib/finance/store.ts` over Drizzle; its
  tests run against the in-memory SQLite database. `fin_settings` keeps the CSV mappings and
  the statistic average as JSON text (no separate `fin_csv_mappings` / `fin_benchmark`
  tables). Foreign keys inside a family are composite without an action; the store does what
  Postgres's `ON DELETE SET NULL (column)` and `delete_finance_category` did.
- The finance routes, JSON shapes and export files are family-planner's (version 2 with
  `finance`; an import replaces the finances in the same transaction as the calendar).
  Not ported: `clone` (Ohana has none; `copyFinance` stays, tested directly), the AI
  categorize route and its buttons (phase 3), the agent page.
- Transactions of one request share one `created_at`, and the list orders a day's
  transactions by `created_at`, then insertion order, so the order is stable (family-planner's
  Supabase store broke ties by id).
- The import's review step also lists the rows, with those imported before struck through.
  The family overview has a finance card (this month in / out, where most went, balance).

### Phase 1 notes (deviations)

- The calendar part of family-planner's `Store` is `lib/calendar/store.ts` over Drizzle; its
  tests run against the in-memory SQLite database (no memory store). Entries of a day come
  back ordered by type id (as from Supabase), not in insertion order.
- The family API (`/api/v1/families/{id}/...`) serves family-planner's family routes that
  belong to the calendar: GET/PATCH the family, types, entries, notes, `links`, `export`,
  `import`, `calendar.ics`. Not ported: `POST /families`, `clone`, `members`, `agent` (Ohana's
  own family management and the assistant replace them), the `/sessions` alias, rate limits on
  writes (Ohana's API needs an account; sign-in is rate limited) and the SPA's offline cache.
- Export files are `family-planner` version 2; since phase 2 with `finance` again (a file
  without it leaves the finances alone).
- Calendar view settings (zoom, always show weekdays, skip weekends) are per device in
  `localStorage`. The settings page got tabs (General, Calendar, Calendar feed).

### Phase 6 notes (the importer, part A)

`scripts/import-legacy.ts` (`npm run import-legacy`, README → "Importing the old apps") is
built for everything but the finances and the assistant; the rehearsal, the real import and
the cut-over are still to do.

- **Code:** `lib/import/` — `accounts.ts` merges users / families / members (stage 1), then the
  `AREAS` list in `index.ts` runs one function per source and area:
  `family-planner/{accounts,calendar}.ts` (API tokens, calendar), `cookless/{accounts,meals}.ts`
  (invites, meals and photos, the Gemini key only reported), `fma/{accounts,appointments}.ts`
  (invites, channels, searches). Finance and the assistant are two more entries there
  (`family-planner/finance.ts`, `family-planner/assistant.ts`, and cookless's Gemini key →
  `ai_settings`); until then the dry run lists the family-planner tables it didn't read.
- **family-planner input:** a `pg_dump --data-only --schema=public` file (no direct
  connection): pg_dump's default COPY format, or `--column-inserts`; a plain `--inserts` dump
  has no column names and is refused. Only `public.*` is read (Supabase's `auth.users` is not
  family-planner's users).
- **One transaction** (deferred foreign keys, checked before the end); `--dry-run` runs it all
  and rolls back. Photos are copied inside it and removed again on failure.
- **Target:** must be migrated; refused when it has accounts or families unless `--force`
  (an existing account with the same email is then kept as it is and gets the memberships).
  The families it would create must not exist, so a second run fails cleanly.
- **Ids:** kept (family-planner's user and family ids, the uuids of cookless and
  findmyappointment), except integer ones (recipe ingredients, steps, …) and the shared
  ingredients / units, which are matched by English name / abbreviation or added.
  `createdAt`s are kept (timestamps are seconds in Ohana, so milliseconds go).
- **Passwords** carried over only when usable: not family-planner's `must_change_password`
  ones, not cookless's / findmyappointment's `CHANGE_PASSWORD` ones, not a hash that verifies
  `admin` or `password` (findmyappointment's Django import gave everyone `password`). Accounts
  without one get `SET_CREDENTIALS` and are listed for a setup link; the others start at
  `ADD_PASSKEY`. Language: cookless's, else findmyappointment's.
- **Defaults:** families from family-planner keep their calendar as it was (no preset types
  added); the others get the preset types (in findmyappointment's household language, else the
  first member's). Default meal tags only for families without cookless tags.
- **Not imported:** sessions, setup links, passkeys, expired / used invites, deactivated
  accounts, findmyappointment's runs, results and profile cache. Searches keep `next_run_at`,
  so the worker runs them soon after; without the run history their first run notifies about
  everything available.

## Decided

- The app lives at the repo root (no `web/`).
- Nothing is redirected: the old domains, calendar feeds included, go away with the old apps.
- After the import, the Supabase project is kept read-only for a while as an extra backup.
