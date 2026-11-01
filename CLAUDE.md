# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Ohana** is one app for a family: calendar, finance, meals, doctor appointments and an
AI assistant. It is **open source and self-hosted** (server AGPL-3.0, app MPL-2.0). The
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
  `ASSISTANT_TICK_MS` (1000) for the assistant's `ChatRunner`; turned-off modules' runners
  don't run). `docker-entrypoint.sh setup-link <email>` prints a setup link. Long-running jobs
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
  `birthdays` by day via `dayExtras`, shown by the app's calendar; the feed with `birthdays=1`: one yearly `RRULE` event each)
  and of the overview (next 30 days, `familyDashboard`).
- **Family REST API** (`lib/api/family-api.ts`, family-planner's `handler.ts`): `http/api.ts`
  runs `createFamilyApi([...routes])` for `/api/v1/families/{id}[/…]`; the first route is
  `handleDisabledModules` (`lib/api/disabled-modules.ts`).
  Each module adds a route function `(ctx: Ctx) => Promise<Response> | null` (null: not my
  path) to that list. `Ctx` has `db`, `store` (calendar part of family-planner's `Store`),
  `finance` (its finance part), `rest` (path after the id), `principal`,
  `requireUser()`, `load(need)` / `loadWith(need, query)` with `need` = `edit` | `view` | `feed`
  (404 for non-members — admins too —, 403 "You can only view this family" for viewers).
  Signed in by an API token (Bearer; the session cookie is still accepted, writes with it need
  a same-origin request). The separate routes (`/recipes`, `/shopping/toggle`, `/geocode`, the
  autocompletes, `/api/images`) take API tokens only (`lib/families/api.ts`
  `requireApiUser` / `requireFamilyApi`). `HttpError` / `AuthError` / `ZodError` become
  `{ "error": … }`. Input helpers in `lib/api/http.ts`. Paths and JSON shapes are
  family-planner's, so its scripts keep working.
- **Calendar (`lib/calendar/`):** family-planner's vacation module.
  `store.ts` is the calendar part of its `Store` interface over Drizzle (`DrizzleCalendarStore`,
  snake_case rows, promise API); `vacation.ts` (types per year, entries, notes, the ICS feed
  route `GET /api/v1/families/{feedId|legacyId}/calendar.ics`, public, never by family id),
  `family-routes.ts` (GET/PATCH family, `links`, `export`/`import`), `ics.ts`, `dates.ts` and
  `core.ts` (pure client logic) are ported with few changes. Tables `cal_entry_types` (PK
  family+year+id), `cal_entries` (with the day's `year`, composite FK to its type: deleting a
  type cascades to its days; never `INSERT OR REPLACE` a type), `cal_notes`; `families.feed_id`
  (random, unique) and `legacy_id` (family-planner's old view id, for the import; also the
  feed's UID prefix). `createFamily` adds the preset types (`presets.ts`) in the creator's
  language. Export / import of the family file: `GET /export`, `POST /import` (checks in
  `lib/calendar/export-file.ts`; family-planner's Clone isn't ported); the overview shows
  `lib/calendar/summary.ts`.
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
  `import_hash` unique per family). References inside a family are composite FKs without an
  action (SQLite can't null one column of a composite key): the store moves or clears them
  before deleting (category → parent, parts of a deleted booking become normal). Within a
  day transactions list newest created first, then in insertion order (rowid); one request's
  ops share one `created_at`. CSV files are parsed by the app; the server stores the saved
  formats (`fin_settings.csv_mappings`). Auto-categorize calls the assistant's
  `POST …/ai/categorize` (so it's off with the assistant). Receipts are scanned and read in
  the app only (`apple/…/Finance/ReceiptScanner.swift`: VisionKit's document camera, Vision
  text recognition, `ReceiptParser`); it saves a plain transaction, then sorts it with
  `…/ai/categorize` (`ids`); the shopping-day link is the usual groceries category + day ± 1.
- **Assistant (`lib/assistant/`):** family-planner's `ai/*`. Tables
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
  `net.ts` refuses private addresses (`AiEnv.modelNet` may allow them for the endpoint with
  `AI_ALLOW_PRIVATE_ENDPOINT`). `toolsFor` leaves out the tools of turned-off modules
  (`toolEnabled`). Tests use
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
  `meals.ts`, `connections.ts`,
  `assistant.ts`).
- **Connections between modules (phase 7):**
  - *Appointments → Calendar:* `cal_events` (`lib/db/schema/connections.ts`): timed events
    (`day`, wall-clock `start`/`end` "HH:MM" or null = all day, title, location, person,
    note, url, `source` manual | appointment with `source_id` = search, `source_item` =
    result; the slot's data is copied, results are pruned). `lib/calendar/events.ts` (CRUD,
    zod `eventInputSchema`, REST `handleEvents`: GET/POST `/events`, DELETE `/events/{id}`),
    `lib/appointments/booking.ts` (`bookSlot` once per slot, optional stop = search disabled;
    `removeBooking`; app routes in `lib/appointments/app-routes.ts`). GET `/families/{id}` adds
    `events` by day (`familyState`'s 4th argument). The feed adds them with `events=1`
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
    finance page, `GET /finance/shopping-links`) and `groceries-links.ts` (`listForTransaction`).
  - *Notifications:* `notification_prefs` (family + event: enabled, `channel_ids` JSON or
    null = all, `state` JSON memory). `lib/notifications/prefs.ts` (`getPrefs`, `setPref`,
    `notifyEvent`; events and defaults in `prefs-shared.ts`), `daily.ts` (`checkCoverage`
    from `NOTIFY_HOUR`: once a day, only when a gap day wasn't told before;
    `remindShopping` from `SHOPPING_REMINDER_HOUR`: once per shopping day; server-local
    days; the shopping reminder only with meals on). `notifyRun` skips when `appointment_found`
    is off.
  - *Overview:* `lib/families/dashboard.ts` (`familyDashboard`, `GET /overview`; no searches
    with appointments off).
  - *Search:* `lib/families/search.ts` (`searchFamily`, `GET /search?q=&today=&limit=`): recipes,
    events, notes, transactions, appointment searches, people (members + `family_people`) and the
    caller's own chats whose text holds every word (`normalizeForSearch`: case and accents
    ignored), grouped by kind, per kind title matches first then nearest to `today`, `limit` per
    kind (`more` counts the rest); turned-off modules are left out. The app's search tab.
- **Meals (`lib/meals/`, ported from cookless):** recipes, meal plan, shopping lists, cook
  view, tags. Tables in `lib/db/schema/meals.ts` (re-exported by `schema.ts`): `ingredients`
  and `units` are shared seed data (`lib/meals/seed.ts`, run by `scripts/seed.ts` at every
  server boot and by `npm run db:migrate`; test DBs aren't seeded, tests insert their own),
  everything else belongs to a family (`meal_plans` → `plan_iterations` → entries and
  shopping lists). Pure logic in `lib/meals/domain/` (selection, schedule, aggregation, units,
  scaling), DB work in `recipes/`, `meal-plan/`, `shopping/`, reads in `queries/`; every
  function takes `familyId` and only touches that family's rows (404 otherwise).
  `createFamily` seeds the default `meal_tags`. App routes in `lib/meals/app-routes.ts` and
  `app-routes-plan.ts` (changes need an editor). REST in `http/api.ts`:
  `/api/v1/families/{id}/{recipes,recipes/{id},shopping/toggle}` (API token,
  `lib/meals/route-auth.ts`; the app's offline shopping queue replays idempotent `set` ops to
  `shopping/toggle`). Photos: `sharp` → WebP under `MEDIA_ROOT` (`recipes/<id>_<ts>.webp`),
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
  request's signal aborted, i.e. the client went away), `stream.ts` (the NDJSON stream
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
  `DISABLED_MODULES` (finance, meals, appointments, assistant; never calendar):
  `moduleEnabled()`; `moduleOfFamilyPath` maps family API paths (finance, meals / recipes /
  shopping, appointments, ai / agent) for `handleDisabledModules`; the worker, the daily
  shopping reminder, the dashboard's searches, `mealsAi` and the assistant's tools check it.
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
  `LoadState.run($state, api.cached(…))` shows the copy at once as `.saved(…, updating:)` with
  `SavedCopyBadge` ("Updating…", "Offline · as of …") and keeps it while the server can't be
  reached; editing waits for the server's answer; `AppModel` opens on the saved account and
  families; signing out or a new pairing clears it; `Core/Support/Connectivity.swift`;
  `Core/API/Prefetch.swift` loads the selected family's main screens and the meal plan's
  recipes in the background after launch / a family switch / reconnecting (every 15 min at most,
  not in Low Data Mode) through the screens' own request builders (`OverviewView.request`,
  `FinanceStore.listRequest`, …: keep them shared, or the screen won't find the copy). Offline
  writes, server wins (a refusal drops the change and reloads): the calendar's queue of entry /
  note ops is kept on disk (`CalendarStore.queueFile`, shown on top of what's loaded); the
  shopping queue holds ticks and adds (`ShoppingTickQueue`, adds carry a `clientId` the server
  applies once: `shopping_item_adds`)),
  `Shell/` (sidebar-adaptable `TabView`, family switcher, assistant `.inspector` ⌘J (a `.sheet` on
  iPhone: an inspector there breaks the tabs' navigation bars), toggled by the ✨ button at the top
  right of every page: module roots get it from `shellToolbar()`, a page pushed onto a module's
  stack adds `.assistantButton()`; and its own
  page, `AppRoute`: `family.open(.recipe(id:))` etc. switches to the module, whose root takes it
  with `family.takeRoute(for:)`; server paths `/f/{id}/…` and `ohana://f/{id}/…` map onto routes;
  the search tab (`Module.search`, `Tab(role: .search)`, ⌘K → `family.startSearch()`,
  `Features/Search/`) opens its hits the same way, a transaction as `.financeTransaction`),
  `DesignSystem/` (solid content cards — Liquid Glass only on bars and floating controls —, error banner, `CancelButton`/`discardGuard`; the module sets `newItem`/`moduleMenu` focused values for File ▸ New and its menu), `Features/<Module>/` (plus `Account/`, `Admin/`).
  Drag and drop (iPad, Mac) carries the payloads of `Core/Support/DragItems.swift` (own UTTypes,
  declared in `project.yml`, each naming its family): a recipe or a planned meal onto a day of the
  meal plan (`MealPlanDrop`; the plan's recipe column, `MealPlanRecipeColumn.swift`), a calendar
  event onto another day (`CalendarEventDrag.swift`, `CalendarStore.moveEvent`; the grids' selection
  gestures step aside on an event label), a shopping item onto another list's chip (`ShoppingMove`).
  The assistant: `family.ask(prompt, send:, newChat:)` opens it ready to type from anywhere (⇧⌘J, the overview's field, the Mac's menu bar item (`MenuBarItem`, an AppKit status item: SwiftUI's `MenuBarExtra` re-sets its icon on every window redraw and crashed the app), the
  `AskOhanaIntent` App Shortcut). Recipes are in Spotlight (`RecipeSpotlight.swift`: every family's,
  after loading the account and after recipe changes; emptied in the demo / with Meals off; a result
  opens `ohana://f/{id}/meals/recipes/{id}`). The recipe list's *Import from Web* sheet
  (`RecipeImportView`, editors, with the meals AI) posts a URL to `…/meals/recipes/import`, then
  offers to open the recipe or undo (DELETE it); so does the share extension. From outside the app: Siri / Shortcuts actions without opening it
  (`App/Intents/CaptureIntents.swift`: add to the shopping list, add an event, import a recipe;
  `IntentConnection`) and the *Save to Ohana* Safari share extension (`apple/ShareExtension/`,
  targets `OhanaShare` / `OhanaShare-macOS`, bundle id `de.fa-krug.Ohana.Share`; iOS sends the
  page's text via `Preprocess.js`). Code both use is in `apple/Shared/` (`Keychain`,
  `SharedConnection`): no App Group — the app mirrors the server URL and selected family into the
  shared Keychain access group next to the token, and removes them on sign out.
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
  Tomorrow, Tonight's dinner, Shopping list, Appointment found (Lock Screen families on iOS only).
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
