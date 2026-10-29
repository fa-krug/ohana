# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Ohana** is one Next.js app for a family: calendar, finance, meals, doctor appointments and an
AI assistant. It replaces `fa-krug/family-planner`, `fa-krug/cookless` and
`fa-krug/findmyappointment`; [docs/plan.md](docs/plan.md) has the decisions, what comes from
which app, and the phases. Phase 0 (accounts, families, admin, shell, worker, deploy),
phase 1 (Calendar), phase 2 (Finance), phase 3 (the assistant: chats in the worker, tools for
every module, recipe generation and AI photos), phase 4 (Meals), phase 5 (Appointments,
notification channels) and phase 7 (connections between the modules) are done.

## Commands

```bash
npm run dev           # Next.js dev server on http://localhost:3000
npm run worker        # background worker (tsx worker/index.ts)
npm test              # Vitest (tests/*.test.ts)
npm run typecheck     # tsc --noEmit
npm run build         # production build (standalone output)
npm run db:generate   # Drizzle migration from lib/db/schema.ts changes
npm run db:migrate    # apply migrations to DATABASE_FILE (default ./data/ohana.db), then db:seed
npm run db:seed       # load the shared units + ingredients (idempotent; also run at `web` boot)
npm run setup-link -- <email>   # print a new setup link for an account
npm run mock-ai       # scripted OpenAI-compatible stand-in on :4011 (web + worker need AI_ALLOW_PRIVATE_ENDPOINT=1)
npm run import-legacy -- --family-planner dump.sql --cookless cookless.db --cookless-media media \
  --fma fma.db --map import-map.json [--family-planner-ai-secret <base64>] --dry-run   # one-time import of the old apps (README)
```

## Architecture

- **Stack:** Next.js 16 (App Router), React 19, TypeScript, Tailwind CSS 4, Radix primitives
  (`components/ui/`), Drizzle ORM over SQLite (`better-sqlite3`, WAL). Schema in
  `lib/db/schema.ts`, migrations in `drizzle/`.
- **Two processes, one image:** `docker-entrypoint.sh web` migrates then serves;
  `docker-entrypoint.sh worker` runs `worker/index.ts` (waits for the migrations, then loops
  every `APPT_TICK_SECONDS` (15): the appointment `SearchRunner`, and every
  `WORKER_TICK_SECONDS` (60) `lib/maintenance/cleanup.ts`, the nightly
  `lib/maintenance/backup.ts` and `lib/notifications/daily.ts`; the loop itself ticks every
  `ASSISTANT_TICK_MS` (1000) for the assistant's `ChatRunner`). Long-running jobs (appointment searches, assistant turns,
  notifications) belong in the worker, never in a request.
- **Auth (`lib/auth/`):** passkeys (`@simplewebauthn`, ceremony state in a signed cookie) and
  argon2id passwords; family-planner's `pbkdf2-sha256$…` hashes are still verified and replaced
  at the next sign-in. Sessions, API tokens and setup links are rows of `auth_tokens`
  (`kind` session | api | setup) holding only the SHA-256 of the token (`tokens.ts`). A session
  opened with a setup link has `canReset` (may set a password without the old one).
  `session.ts`: `getAuth()` (cookie), `getApiUser(req)` (Bearer API token),
  `requireAdminPage()`. Password sign-in is rate limited (`rate-limit.ts`). Onboarding steps:
  SET_CREDENTIALS (admin-created account, via setup link) → ADD_PASSKEY (optional) → COMPLETED.
  The first account (`/setup`, only while there are no users) is an admin.
- **Families (`lib/families/`):** every piece of data belongs to a family; members are
  `editor` or `viewer` (`roles.ts`: `requireRole` gives 404 to non-members, 403 to viewers
  where an editor is needed; an `Actor` with `admin: true` is used only by the admin actions).
  A family always keeps an editor. Pages under `app/(app)/f/[familyId]/` call
  `requireFamily(familyId)` (`page.ts`) themselves; don't rely on the layout's check, Next
  renders layout and page in parallel. Admin pages likewise call `requireAdminPage()`.
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
  `birthdays` by day via `dayExtras`: `PlannerStore.birthdays`, the grid's `.birthday-mark`
  🎂, tooltip and selection bar; the feed with `birthdays=1`: one yearly `RRULE` event each)
  and of the overview (next 30 days, `familyDashboard`).
- **Server actions** live in `app/actions/*.ts` and wrap their work in `run()`
  (`lib/actions/result.ts`), which signs in the user (and checks admin with `{ admin: true }`)
  and turns `AuthError` / `ZodError` into `{ ok: false, status, message }`.
- **Family REST API** (`lib/api/family-api.ts`, family-planner's `handler.ts`): one route,
  `app/api/v1/families/[familyId]/[[...path]]/route.ts`, runs `createFamilyApi([...routes])`.
  Each module adds a route function `(ctx: Ctx) => Promise<Response> | null` (null: not my
  path) to that list. `Ctx` has `db`, `store` (calendar part of family-planner's `Store`),
  `finance` (its finance part), `rest` (path after the id), `principal`,
  `requireUser()`, `load(need)` / `loadWith(need, query)` with `need` = `edit` | `view` | `feed`
  (404 for non-members — admins too —, 403 "You can only view this family" for viewers).
  Signed in by an API token (Bearer) or the session cookie (read from the request; cookie
  writes need a same-origin request). `HttpError` / `AuthError` / `ZodError` become
  `{ "error": … }`. Input helpers in `lib/api/http.ts`. Paths and JSON shapes are
  family-planner's, so its scripts keep working.
- **Calendar (`lib/calendar/`, `components/calendar/`):** family-planner's vacation module.
  `store.ts` is the calendar part of its `Store` interface over Drizzle (`DrizzleCalendarStore`,
  snake_case rows, promise API); `vacation.ts` (types per year, entries, notes, the ICS feed
  route `GET /api/v1/families/{feedId|legacyId}/calendar.ics`, public, never by family id),
  `family-routes.ts` (GET/PATCH family, `links`, `export`/`import`), `ics.ts`, `dates.ts` and
  `core.ts` (pure client logic) are ported with few changes. Tables `cal_entry_types` (PK
  family+year+id), `cal_entries` (with the day's `year`, composite FK to its type: deleting a
  type cascades to its days; never `INSERT OR REPLACE` a type), `cal_notes`; `families.feed_id`
  (random, unique) and `legacy_id` (family-planner's old view id, for the import; also the
  feed's UID prefix). `createFamily` adds the preset types (`presets.ts`) in the creator's
  language. The page is client-side: `PlannerStore` (`planner-store.ts`: save queue, polling,
  undo/redo, selection) + the imperative `GridView` (`grid.ts`, CSS in `calendar.css`, colors
  `--cal-*` in `globals.css`); per-device prefs in `view-prefs.ts`. Settings has tabs
  (`components/families/settings-tabs.tsx`: general, household, calendar, feed, finance, ai,
  data: export / import of the family file, `data-settings.tsx`, checks in the browser-safe
  `lib/calendar/export-file.ts`; family-planner's Clone isn't ported);
  the overview shows `lib/calendar/summary.ts`.
- **Finance (`lib/finance/`, `components/finance/`):** family-planner's finances. `store.ts`
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
  `import_hash` unique per family). References inside a family are composite FKs without an
  action (SQLite can't null one column of a composite key): the store moves or clears them
  before deleting (category → parent, parts of a deleted booking become normal). Within a
  day transactions list newest created first, then in insertion order (rowid); one request's
  ops share one `created_at`. The page is client-side: `FinanceStore` (`finance-store.ts`:
  period, filters, selection, undo toasts) with the views; settings in
  `finance-settings.tsx` (a tab of Settings). Auto-categorize (button, import option) calls
  the assistant's `POST …/ai/categorize`.
- **Assistant (`lib/assistant/`, `components/assistant/`):** family-planner's `ai/*`. Tables
  `ai_settings` (keys sealed with `getSecretBox()`), `chats` (status, lease `run_token` /
  `run_until`, `stop`, JSON `context` / `activity` / `notes` / `usage` / `queue`, `rev`),
  `chat_items` (what the chat shows, by `seq`, with the `rev` it changed in), `chat_messages`
  (what the model gets, append-only, summaries among them) in `lib/db/schema/assistant.ts`;
  `store.ts` is the AI part of the `Store` (`DrizzleAssistantStore`, `ctx.assistant`; queue and
  item revisions in immediate transactions). Routes: `routes.ts` `handleAi(env)` (settings,
  models, test, categorize, `/agent`) and `chat-routes.ts` (chats; they save the message and
  leave the chat running without a holder, then stream it from the database). **Turns run
  only in the worker:** `runner.ts` `ChatRunner.tick()` claims waiting chats (`pendingChats`,
  `claimChatNow`) and runs `chats.ts` `Runner` (the tool loop `chat.ts` `runChat` against
  `provider.ts`, items/messages saved as it goes, lease renewed, stop/delete noticed per
  tick). `prepareTurn` builds the instructions and tools; viewers and `allow_writes: false`
  get only the tools that read. Tools by module in `tools/` (`calendar.ts`, `events.ts`
  (cal_events), `finance.ts`, `meals.ts`, `appointments.ts`, `general.ts`, `web.ts`, registry
  `index.ts`; `runTool` turns `HttpError` / `AuthError` / `ZodError` into the model's
  `{"error"}`); every change returns undo steps (requests on the family API the client
  replays; meals' and appointments' undo routes are `lib/meals/family-routes.ts`
  `handleMeals` (`/meals/recipes/{id}`, `/meals/shopping/check|items/{id}`,
  `/meals/plan/restore` with `meal-plan/snapshot.ts`, `/meals/plan`) and
  `lib/appointments/family-routes.ts` (`/appointments/searches/{id}`); POST `/events` with
  `searchId` + `resultId` puts a booking back). `ToolContext` carries `userId` (the chat's
  user: the lib functions' `Actor`), `today`, `now` and `lookups` (Doctolib / Photon; tests
  fake them via `AiEnv.lookups`). The system prompt (`chat.ts`) lists the meal tags and the
  home address. `notify.ts` is the "assistant turn finished" notification (`RunnerEnv.turnEnded`
  from the `ChatRunner`; `chats.seen_at`, set every 15 s by a follower, says someone looks).
  `net.ts` refuses private addresses (`AiEnv.modelNet` may allow them for the endpoint with `AI_ALLOW_PRIVATE_ENDPOINT`). Client: `ChatStore`
  (`chat-store.ts`) in `AssistantProvider` (the shell, per family), `chat-panel.tsx`,
  `ai-settings.tsx` (Settings → AI); changes notify the pages through `events.ts`. Tests use
  `lib/test/assistant.ts` (fake fetch + `lib/test/mock-ai.ts`, a ticking `ChatRunner`);
  `npm run mock-ai` serves the mock for trying it out.
- **UI:** `components/shell/app-shell.tsx` is the frame (left sidebar with family switcher,
  modules from `components/shell/modules.ts`, account menu; collapsible to an icon rail,
  `Ctrl/⌘+B`, remembered per device; right assistant panel, `Ctrl/⌘+J`; both are sheets on
  phones). A module that isn't built yet is served by
  `app/(app)/f/[familyId]/[module]/page.tsx`; a built one gets its own folder, which wins over
  the dynamic segment; set `ready: true` in `modules.ts` then. Theme: light / dark / system
  per device (Account page; `lib/theme.ts`, `theme-client.ts`), applied by a blocking script
  in the root layout's `<head>` as `.dark` on `<html>` (the `dark:` variant is class-based).
  The calendar asks before the page is closed while changes are still being saved.
- **Secrets (`lib/secrets.ts`):** `SecretBox` (port of family-planner's): AES-256-GCM,
  `v1:<base64 iv+ciphertext+tag>`, keyed by `ENCRYPTION_KEY` or else HKDF(`AUTH_SECRET`,
  info "ohana-secrets"). `getSecretBox()` for channel tokens / SMTP passwords and the AI / search keys. Stored secrets never go back to the browser: DTOs say `hasToken`, a blank field on
  edit keeps the stored value.
- **Notifications (`lib/notifications/`), family-wide:** `notification_channels` (Pushbullet,
  Pushover, Telegram, email/SMTP; `token` sealed). `channels.ts` CRUD (editors),
  `notifyFamily(db, familyId, message, { channelIds?, send? })` in `index.ts` sends to the
  enabled channels (`channelIds: []` = none, omitted = all); a failing channel is logged and
  counted, never thrown. `send.ts` holds the network senders (untested); `locale.ts` picks the
  family's language (its longest-standing editor's). UI: `components/families/notifications-card.tsx`
  in Settings → Household (editors only), with "Test".
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
  `lib/families/home.ts`, Photon-geocoded) gives the distance on the slot page. Pages under
  `app/(app)/f/[familyId]/appointments/`, actions in `app/actions/appointments.ts`,
  autocomplete routes under `app/api/v1/families/[familyId]/` (members; session or API token).
- **Schema files:** `lib/db/schema.ts` holds accounts + families and re-exports one file per
  module from `lib/db/schema/` (`notifications.ts`, `appointments.ts`, `finance.ts`,
  `meals.ts`, `connections.ts`,
  `assistant.ts`).
- **Connections between modules (phase 7):**
  - *Appointments → Calendar:* `cal_events` (`lib/db/schema/connections.ts`): timed events
    (`day`, wall-clock `start`/`end` "HH:MM" or null = all day, title, location, person,
    note, url, `source` manual | appointment with `source_id` = search, `source_item` =
    result; the slot's data is copied, results are pruned). `lib/calendar/events.ts` (CRUD,
    zod `eventInputSchema`, REST `handleEvents`: GET/POST `/events`, DELETE `/events/{id}`),
    `lib/appointments/booking.ts` (`bookSlot` once per slot, optional stop = search disabled;
    `removeBooking`), actions `bookSlotAction` / `removeBookingAction`, UI
    `components/appointments/{book-dialog,booked-list}.tsx`. GET `/families/{id}` adds
    `events` by day (`familyState`'s 4th argument): `PlannerStore.events`, the grid's
    `.event-mark`, title tooltip and the selection bar. The feed adds them with `events=1`
    (`buildIcs` `events`: floating local times, `DURATION:PT1H` without an end). The
    assistant's tools reach every module (meals, appointments, events; see Assistant).
  - *Calendar → Meals:* `cal_entry_types.away` (optional `away` in the type API, export and
    import; `TypeRow.away?`). `lib/meals/meal-plan/away.ts` `awayDays`; `populateIteration`
    passes them as `assignSchedule({ skipDates })` and counts cooking sessions from the days
    at home; the plan page shows "Away · Type".
  - *Meals → Finance:* `fin_settings.groceries_category_id` (null: the category named
    Groceries / Lebensmittel; PATCH `/finance/settings` `groceriesCategoryId`, GET
    `/finance` returns it). `lib/finance/groceries.ts` (`shoppingSpend`: `findTransactions`
    in the category's subtree on the shopping day ± 1, net totals; `shoppingLinks` for the
    finance page) and the browser-safe `groceries-links.ts` (`listForTransaction`). UI:
    `components/meals/shopping/spent-card.tsx`, `components/finance/shopping-links.tsx`.
  - *Notifications:* `notification_prefs` (family + event: enabled, `channel_ids` JSON or
    null = all, `state` JSON memory). `lib/notifications/prefs.ts` (`getPrefs`, `setPref`,
    `notifyEvent`; events and defaults in `prefs-shared.ts`), `daily.ts` (`checkCoverage`
    from `NOTIFY_HOUR`: once a day, only when a gap day wasn't told before;
    `remindShopping` from `SHOPPING_REMINDER_HOUR`: once per shopping day; server-local
    days). `notifyRun` skips when `appointment_found` is off. UI
    `components/families/notification-events-card.tsx` (Settings → Household).
  - *Overview:* `lib/families/dashboard.ts` (`familyDashboard`) + `app/(app)/f/[familyId]/page.tsx`.
- **Family settings:** `FamilySettings` (General tab) renders its `children` before "Leave or
  delete"; the home address and the notifications are on the Household tab
  (`HouseholdSettings` in `settings/page.tsx`).
- **Meals (`lib/meals/`, ported from cookless):** recipes, meal plan, shopping lists, cook
  view, tags. Tables in `lib/db/schema/meals.ts` (re-exported by `schema.ts`): `ingredients`
  and `units` are shared seed data (`lib/meals/seed.ts`, run by `scripts/seed.ts` at every
  `web` boot and by `npm run db:migrate`; test DBs aren't seeded, tests insert their own),
  everything else belongs to a family (`meal_plans` → `plan_iterations` → entries and
  shopping lists). Pure logic in `lib/meals/domain/` (selection, schedule, aggregation, units,
  scaling), DB work in `recipes/`, `meal-plan/`, `shopping/`, reads in `queries/`; every
  function takes `familyId` and only touches that family's rows (404 otherwise).
  `createFamily` seeds the default `meal_tags`. Server actions in `app/actions/meals.ts` (all
  need an editor); pages `app/(app)/f/[familyId]/meals/{recipes,plan,shopping,cook,tags}`
  (tabs: `components/meals/meals-tabs.tsx`; `MealsProvider` gives client components
  `familyId` / `canEdit` / `base`); components in `components/meals/`. REST:
  `app/api/v1/families/[familyId]/{recipes,recipes/[id],shopping/toggle}` (session or API
  token, `lib/meals/route-auth.ts`). Photos: `sharp` → WebP under `MEDIA_ROOT`
  (`recipes/<id>_<ts>.webp`), served by `app/api/images/[...path]` to members of the recipe's
  family only (`lib/meals/images/serve.ts`). Offline: `lib/offline/` queues shopping ticks in
  IndexedDB (idempotent `set` ops) and replays them to their family's route;
  `public/sw.js` caches the meals pages (registered by the meals layout in production,
  cleared on sign-out). **AI** (`lib/meals/ai/`, from cookless's `lib/ai`): `prompt.ts`
  (ported), `recipes.ts` (prompt context, tag/unit ids, `generateRecipeImage`), `generate.ts`
  (one chat completion through `lib/assistant/provider.ts` with the family's model —
  `familyModel()` in `lib/assistant/routes.ts` —; photos via `POST {base}/images/generations`
  with `ai_settings.image_model`, or Gemini's native `generateContent` for a Gemini image model
  on Gemini's endpoint), `verify.ts` (zod check of the answer), `stream.ts` (the NDJSON stream
  of `POST /api/v1/families/{id}/recipes/generate`, inline in the web process: one
  user-started call with timeouts, cancelled with the request), `stream-client.ts`, `status.ts`
  (`mealsAi`: show the buttons). Saving: `recipes/bulk-create.ts` (`bulkCreateRecipesAction`);
  photo: `generateRecipeImageAction`. Page `meals/recipes/generate`
  (`components/meals/recipes/generate-recipes.tsx`).
- **Legacy import (`lib/import/`, `scripts/import-legacy.ts`):** one-time import of
  family-planner (a `pg_dump --data-only` file, parsed by `pgdump.ts`: COPY or
  `--column-inserts`, `public` schema only), cookless and findmyappointment (their SQLite
  files, read-only, schema checked). Stage 1 (`accounts.ts`): users merged by lowercased email,
  families by `import-map.json`, members combined (editor wins); fills `ctx.userIds` /
  `ctx.familyIds` (source id → Ohana id). Stage 2: the `AREAS` list in `index.ts`, one function
  per source and area (`family-planner/` accounts + tokens, calendar, finance, assistant;
  `cookless/` invites, meals, Gemini key; `fma/`). AI keys: family-planner's are opened with
  its `AI_CONFIG_KEY` (`--family-planner-ai-secret` / `FAMILY_PLANNER_AI_SECRET`,
  `ctx.familyPlannerSecrets`) and sealed with Ohana's, else dropped and listed in
  `report.aiKeys`; a running chat comes over as running without a holder with `stop` set (the
  worker ends it as stopped, no model call), queues are dropped; cookless's Gemini key fills
  only families without family-planner AI settings. Afterwards `addDefaults` gives families
  what `createFamily` would where the import brought nothing (preset types, finance
  categories, meal tags). All in one SQLite transaction (deferred FKs, checked at the
  end); `--dry-run` rolls back; photos copied into `MEDIA_ROOT` inside it and removed on
  failure. Refuses a non-empty target without `--force` and families that exist already.
  Tests: `tests/import-*.test.ts`, fixtures built by `lib/test/legacy.ts` from the old apps'
  migrations in `tests/fixtures/legacy/{cookless,fma}/drizzle` and the hand-written dump
  `tests/fixtures/legacy/family-planner.sql`.
- **i18n:** `lib/i18n/locales/{en,de}.json`, `useT()` on the client, `getI18n()` on the server.
  Tests check that both files have the same keys and that every literal `t("…")` key exists.

## Conventions

- Tests use an in-memory database with all migrations (`lib/test/db.ts`), factories in
  `lib/test/factories.ts` (appointments: `lib/test/appointments.ts`), fixtures in
  `tests/fixtures/`, and a software passkey (`lib/test/authenticator.ts`) so WebAuthn flows
  run against the real verification. Nothing in tests touches the network (fake clients,
  injected `send` / sources).
- Keep env names clear of Vite/Vitest's: the public URL is `APP_URL` (Vitest sets `BASE_URL`).
- Deploy: pushing to `main` builds and redeploys (see the `deploy` skill and README).
