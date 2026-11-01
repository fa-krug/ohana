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
| Name / repo     | **Ohana**, repo `fa-krug/ohana` (the app at the repo root); the server at `ohana-app.fa-krug.de`, the website at `ohana.fa-krug.de`                                                                                 |
| Approach        | A **new app**, taking the best parts of the three; the old apps run on until their data has moved                                                              |
| Hosting         | **Raspberry Pi** (since phase 8 also anyone's own server: open source, images on GHCR), one Docker image, Traefik on the `gitops_default` network, redeployed by CI through Arcane (GitHub OIDC), like cookless and findmyappointment |
| Database        | **SQLite** (`better-sqlite3`, WAL) with **Drizzle**; one file under `/app/data`, plus `/app/data/media` for images                                             |
| Framework       | **Next.js 16** (App Router), React 19, TypeScript, Tailwind 4, Radix / shadcn-style `components/ui`; since phase 8 **Hono**, no web UI (the native app is the client) |
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
  `/app/data`, Traefik labels for `ohana-app.fa-krug.de`, network `gitops_default`.
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
| 3  | Assistant ✅       | Chats in the worker, calendar + finance tools, web search, analytics, calc, auto-categorize (part A) ✅; tools for meals, appointments and calendar events, recipe generation and AI photos, "assistant turn finished" notification (part B) ✅ |
| 4  | Meals ✅           | Recipes, meal plan, shopping list, cook view, offline queue ✅ (recipe generation, AI photos and the assistant's meal tools came with phase 3 part B) |
| 5  | Appointments ✅    | Doctolib + jameda searches, worker scheduling, slot detail, notification channels; assistant tools for appointments                        |
| 6  | Import + cut-over  | `import-legacy.ts` with dry run, a rehearsal on a copy, then the real import; old apps shut down, Supabase set read-only, old repos archived |
| 7  | Connections ✅     | The cross-module features above, the assistant's tools everywhere (item 4) with phase 3 part B |
| 8  | Headless, open source | No web UI: the native app is the client; a lean server (Hono) with only the sign-in pages; self-hosting docs, GHCR images, AGPL / MPL (see Phase 8) |
| 9  | Push to the app (draft) | Notifications straight to the app from any self-hosted server, through a push relay run by fa-krug that holds the APNs key and sees only ciphertext (see Phase 9) |

### Phase 8: headless, open source, self-hosted

Ohana is not sold. It is an open-source app the family runs on its own server; the native app
(`apple/`) is the only client. Decisions:

| Topic | Decision |
| ----- | -------- |
| Web UI | **Removed.** No module pages, no client stores, no server actions, no service worker. Only the pages that need the server's own domain stay: sign-in, first-run setup, setup links, invites, onboarding, pairing the app, and a small account page for passkeys and the email (the app opens it in `ASWebAuthenticationSession`, as for pairing; a self-hosted server's domain can't be an associated domain of an App Store app). |
| Server | **Hono** on `@hono/node-server` instead of Next.js; `web/` becomes `server/`. Pages are server-rendered with `hono/jsx`, one small browser script (`client/`, bundled by esbuild) does the WebAuthn ceremonies and the forms; plain CSS, no Tailwind. Run with `tsx`, like the worker. |
| Links | Notification links keep `/f/{id}/…`; the server answers them with a page that opens `ohana://f/{id}/…` (no universal links, see above). |
| Compatibility | `GET /api/v1/server` (public): name, version, API version, enabled modules. The app refuses a server with an API version older than it needs, and hides turned-off modules. Changes to the API add, they don't remove. |
| Modules | `DISABLED_MODULES` (comma list of `finance`, `meals`, `appointments`, `assistant`; the calendar is always on): their routes answer 404, the worker skips their jobs, the assistant loses their tools. |
| Push | A new channel **ntfy** (topic URL, optional access token): self-hostable push with an iOS app. A server can't use APNs without the developer's key, so no relay. *Revised in phase 9: an opt-in relay with end-to-end encrypted payloads, ntfy and the other channels stay.* |
| API description | `docs/openapi.yaml` (OpenAPI 3.1), written by hand from the route modules. |
| License | Server (`server/`) **AGPL-3.0**, app (`apple/`) **MPL-2.0** (fits App Store distribution). |
| Images | **GHCR** only: `ghcr.io/fa-krug/ohana`. Every push to `main` is a release (`:latest`, `:main`, `:sha-<commit>`); no release tags. |
| Import | The one-time import of the old apps is done and removed (`lib/import`, `import-legacy`, fixtures). |

Steps:

1. Delete `app/(app)`, `components/` (but what the sign-in pages need), the server actions,
   `lib/offline`, `public/sw.js` (replaced by one that unregisters itself) and the lib files only
   the UI used; their tests and dependencies with them. Locale files keep only the keys the
   server uses.
2. Port the API routes (`app/api/**/route.ts`) and the sign-in pages to Hono (`server/http/`);
   the session and ceremony cookies and the locale read the request through an
   `AsyncLocalStorage` context instead of `next/headers`. Server actions the sign-in pages used
   become JSON routes under `/api/auth/…`.
3. Add the account page (`/account`: add a passkey, change the email with the password or a
   passkey), the landing page after sign-in (`/`: signed in as …, open the app, sign out), and
   `/f/*` → `ohana://f/*`.
4. `GET /api/v1/server`, `DISABLED_MODULES`, the ntfy channel (server and app).
5. App: version check, hidden modules, ntfy, the account page instead of "on the web page".
6. Remove the legacy import.
7. Open source: LICENSE files, CONTRIBUTING, SECURITY, a self-hosting guide (compose file,
   `.env.example`, reverse proxy, HTTPS for passkeys, backups, local AI with Ollama), GHCR
   publishing, `docs/openapi.yaml`.

### Phase 9: push to the app through a relay (draft)

Today a family gets notifications only through the channels it sets up (ntfy, Pushover,
Pushbullet, Telegram, email): a second app, and a tap doesn't open Ohana. Apple delivers
notifications to an app only through APNs, and APNs takes a push for `de.fa-krug.Ohana` only
when it is signed with an auth key of the team that owns the bundle id (HS26J3YA63). That key
can't be in the open-source server or with self-hosters: it reaches every install of the app.
So, like Nextcloud, Bitwarden, Home Assistant or Matrix's Sygnal, fa-krug runs a small **push
relay** that holds the key, and every self-hosted server sends through it. The relay never
sees what a notification says: the app and its own server share a key, the server encrypts,
the app's Notification Service Extension decrypts on the device.

```
 app ── POST /v1/register {APNs token} ──▶ relay ─── relayToken ──▶ app
 app ── PUT /api/v1/me/push {relayToken, key} ──▶ its server
 server (worker) ── POST /v1/send {relayToken, ciphertext} ──▶ relay ──▶ APNs ──▶ device
                                                    the extension decrypts and shows it ◀──┘
```

Decisions:

| Topic | Decision |
| ----- | -------- |
| Relay | A new service **`relay/`** in this repository (Hono on Node 22 like the server, AGPL-3.0, image `ghcr.io/fa-krug/ohana-relay`, its own workflow on `relay/**` changes). **Stateless**: no database, only its secrets and in-memory rate limits. fa-krug's runs at `https://ohana-push.fa-krug.de` on the Pi (Traefik, Arcane, like the server). |
| APNs | Token-based auth (`.p8` key, `APNS_KEY_ID`, `APNS_TEAM_ID`), HTTP/2 to `api.push.apple.com` / `api.sandbox.push.apple.com` with `node:http2`, the ES256 JWT renewed every 50 min. Topic `de.fa-krug.Ohana` for iOS and macOS (one bundle id). |
| Opt-in | Twice. The **server operator** can turn it off (`PUSH_RELAY_URL=` empty; default fa-krug's relay), then nothing changes for that server. Each **person** turns it on per device in the app (and iOS asks for permission). The channels stay as they are, as the fallback and for anyone who doesn't want the relay. |
| Privacy | The payload is **end-to-end encrypted** (AES-256-GCM with a key per device the app made and gave only to its server). The relay and Apple see: the device token, the server's IP, when and how big. The visible fallback text and the collapse id carry nothing either (below). The relay logs no tokens and no payloads, only counters. |
| Device identity | The relay hands out the token servers send to: `relayToken` = the APNs token, environment and platform sealed with the relay's own key (AES-256-GCM). Servers never see an APNs token, the relay stays without a database, and it only takes tokens it issued. |
| Who gets it | The devices of the family's **members** (editors and viewers) that turned push on and didn't mute that family on that device. "Assistant turn finished" goes only to the devices of the chat's own user (the chat is one person's; the channels can't do that). |
| Which events | As the channels: `notification_prefs` gets an **`app`** flag per event (default on), appointment searches a **`notifyApp`** flag (default on). Not a new channel provider: older apps decode `provider` as a closed enum and would fail on the channel list. |
| Compatibility | Only additions (a table, routes under `/api/v1/me/push`, fields in the prefs, the searches and `GET /api/v1/server`); no `API_VERSION` raise. An older app just never registers. |
| Forks | Someone who builds the app under their own bundle id runs `relay/` with their own key and sets the relay URL in the app's `Info.plist` and `PUSH_RELAY_URL` on their server. |

**The relay** (`relay/`):

- `POST /v1/register` (from the app): `{ apnsToken (hex), environment: production | sandbox,
  platform: ios | macos }` → `{ relayToken }` (`r1.` + base64url of iv + ciphertext + tag;
  a fresh IV each time). Rate limited per IP.
- `POST /v1/send` (from servers): `{ messages: [{ relayToken, payload, collapseId?, ttl? }] }`,
  up to 100 per request → `{ results: [{ status }] }` per message: `ok`, `gone` (APNs 410 /
  `BadDeviceToken` / `Unregistered`: the server forgets the device), `invalid` (a token it
  can't open, a payload too big), `limited` (with `retryAfter`), `error` (APNs failed; the
  server counts it as a failed send). `payload` is opaque base64, at most 3 000 bytes;
  `collapseId` opaque, at most 64 bytes; `ttl` at most 24 h (default 24 h).
- It builds the APNs request itself, so a server can't put text of its own on a lock screen:
  `{"aps":{"alert":{"loc-key":"PUSH_FALLBACK"},"mutable-content":1,"sound":"default"},"o":"<payload>"}`
  with `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration`, `apns-collapse-id`.
  `PUSH_FALLBACK` ("New notification from Ohana" / "Neue Mitteilung von Ohana") is in the
  app's strings: shown only when the extension can't decrypt.
- Limits in memory: per relay token 30 a minute and 500 a day, per source IP 1 000 a minute,
  64 KB bodies. `GET /health`. One instance; limits don't need to survive a restart.
- Env: `APNS_KEY` (the `.p8`'s text), `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`
  (`de.fa-krug.Ohana`), `RELAY_SECRET` (32 bytes, base64) and `RELAY_SECRET_OLD` while
  rotating (tokens of the old key are still opened; once it's gone, sends answer `gone`, the
  servers forget those devices and the apps register again at their next start).
- Tests with a fake APNs client: sealing, tampered tokens, size and rate limits, the APNs
  answers mapped to the statuses.

**The server:**

- `PUSH_RELAY_URL` (default `https://ohana-push.fa-krug.de`; empty turns push off). `GET
  /api/v1/server` adds `push: { relay: "<url>" }` or `push: null`, so the app shows the
  switch only where it works.
- Table `push_devices` (account data, `lib/db/schema.ts`): `id`, `user_id` (cascade),
  `token_id` → `auth_tokens` (cascade, unique: the API token that registered it, so the app's
  sign out (`DELETE /api/v1/me`) and revoking a device on the account page remove its push
  too), `platform`, `relay_token` and `key` (both sealed with `getSecretBox()`),
  `muted_family_ids` (JSON, default `[]`), `created_at`, `last_sent_at`, `last_error`.
- Routes (`lib/push/app-routes.ts`, on the app router; API token only, the device is the
  calling token): `GET /api/v1/me/push` → `{ registered, mutedFamilyIds }`; `PUT` `{ relay,
  relayToken, key (base64, 32 bytes), platform, mutedFamilyIds? }` (idempotent; 409 when
  `relay` isn't this server's `PUSH_RELAY_URL`: the server only ever posts to its own relay,
  never to a URL a client names; 404 when push is off); `PATCH` `{ mutedFamilyIds }`;
  `DELETE`; `POST /api/v1/me/push/test` (one push to this device, in the request with a 10 s
  timeout, like the channels' test).
- `lib/push/`: `relay.ts` (the client, 10 s timeout, batches of 100), `payload.ts` (the
  plaintext `{ v: 1, title, body, path, familyId, event? }` where `path` is the message's URL
  without `APP_URL` (`/f/{id}/…`, which the app already routes); sealed with the device key:
  12-byte IV + ciphertext + 16-byte tag, base64, the layout CryptoKit's `AES.GCM.SealedBox
  (combined:)` reads; the body shortened until it fits 3 000 bytes), `deliver.ts`
  (`pushToFamily(db, familyId, message, { userIds?, collapseKey?, push? })`: the members'
  unmuted devices, `gone` deletes the device, a failure is logged in `last_error`, never
  thrown). The collapse id is `base64url(SHA-256(key ‖ collapseKey))` cut to 22 characters, so
  it says nothing either (collapse keys: the chat for the assistant, family + day for the
  shopping reminder, the family for the coverage alert, the search for appointments).
- `notifyFamily` gets `app?: boolean | { userIds: string[] }` and counts pushes in
  `NotifyResult`, so "advance `earliestSeen` only after a successful send" and the coverage
  alert's "remember only what was told" also hold when the app is the only way out.
  `notifyEvent` passes the pref's `app`, `notifyRun` the search's `notifyApp`,
  `notifyTurnFinished` `{ userIds: [chat.user_id] }`. Everything still runs in the worker.
- Migration: `push_devices`, `notification_prefs.app` (default 1), `appt_searches.notify_app`
  (default 1). The prefs and search routes, the assistant's search tools and
  `docs/openapi.yaml` take the new fields.
- Tests (`send` / `push` injected, no network): registration and its 409 / 404, sign out
  removes the device, payload sealing against a fixed vector (the app's tests use the same),
  member / mute / `userIds` selection, `gone` deletes, prefs and searches with `app` off.

**The app:**

- Push Notifications capability (`aps-environment`: development for Debug, production for
  TestFlight / App Store) on both targets. New XcodeGen targets **`OhanaNotificationService`**
  (iOS) and **`OhanaNotificationService-macOS`**, app extensions embedded in their apps, with
  the same `keychain-access-groups` entry, so they read the device key from the Keychain
  (no App Group needed). The relay URL is `OhanaPushRelay` in both `Info.plist`s.
- The extension: decrypts `o` with CryptoKit, sets title, body, `threadIdentifier` (the
  family, so notifications group by family) and `userInfo["path"]`; on any failure it leaves
  the fallback text. The decryption is a plain function in the shared sources, tested with
  the server's vector.
- Turning it on: Account → *Notifications on this device* (and a one-time card on the
  overview after pairing, not a prompt at launch): permission → `registerForRemoteNotifications`
  → `POST /v1/register` with the token and the build's environment → a new random key in the
  Keychain → `PUT /api/v1/me/push`. While on, the app registers again at every start (APNs
  tokens change; the PUT is idempotent). Per family a switch (`mutedFamilyIds`), a *Send a test*
  button. Off, sign out and switching servers: `DELETE /api/v1/me/push` first, then the key is
  deleted. Hidden in the demo and when `push` is null.
- A tap: `UNUserNotificationCenterDelegate` → `AppModel`'s link handling with `path` (switches
  the family if it's another one). In the foreground: banner and sound.
- Strings in `apple/Localization/*.de.json` (`PUSH_FALLBACK` among them); the privacy
  manifest needs nothing new.

**Docs:** `docs/self-hosting.md` (what push is, what the relay sees, `PUSH_RELAY_URL`, the
server needs outbound HTTPS to the relay, how to turn it off, running your own relay for a
fork), the privacy policy (a *Push notifications* section: the relay run by fa-krug and Apple's
APNs get the device token, the server's address and the timing, never the content), a page for
`relay/` (`relay/README.md`), `docs/openapi.yaml`, CLAUDE.md.

Steps:

1. Apple Developer: enable Push Notifications for the App ID `de.fa-krug.Ohana`, create an
   APNs auth key, put it with `RELAY_SECRET` in the relay's Arcane environment.
2. `relay/` with its tests, image workflow and compose service; deploy, check `/health`.
3. Server: migration, `lib/push/`, routes, the hooks in `notifyFamily` / `notifyEvent` /
   `notifyRun` / `notifyTurnFinished`, `GET /api/v1/server`, openapi, tests.
4. App: entitlements, the two extension targets, registration and settings, tap routing,
   strings; check on a device with a Debug build (sandbox) and in TestFlight (production).
5. Docs and privacy policy, released together with the app version that turns it on.

Open questions:

- **Abuse of `/v1/register`:** anyone can get relay tokens for their own devices, which lets
  them push only the fallback text to themselves. If it's abused anyway (APNs throttling the
  key), add App Attest (iOS) / DeviceCheck to registration.
- **The relay as a single point of failure** for every server's pushes: acceptable while the
  channels still work without it; watch `/health` with the server's uptime check.
- **Time-sensitive notifications** for "appointment found" (`interruption-level`, needs an
  entitlement and a payload field the relay sets): later, if wanted.

### Phase 7 notes (connections)

Built: all items of [Connections](#connections-between-modules), a new overview and a
*Household* settings tab. Item 4 (assistant tools for recipes, meal plans and appointment
searches) and the "assistant turn finished" notification came with phase 3 part B (see its
notes). One migration, `0005_connections` (two tables, two columns; nothing to backfill).

- **Appointments → Calendar: timed events are their own table**, `cal_events`, not entries:
  entries are a type on a day (colors, roles, coverage, all-day runs in the feed), while an
  appointment has a time, a place, a person and a link and must not change coverage. Times
  are wall-clock `"HH:MM"` (no time zone in the data, like the rest of the calendar); the feed
  writes them as floating times, so a subscribed phone shows them at that local time. The
  slot's details are **copied** into the event (results are pruned after 30 days; deleting
  the search keeps the event); `source_id` / `source_item` (search / result) only tie it
  back, e.g. to show "Booked for …" on the slot page and to book a slot once. "Mark as
  booked" asks for date and time (prefilled with the slot's, in the browser's time zone),
  for whom, a note, and optionally *Stop watching this search* (turns it off; on by default
  while the search runs). Removing a booking only removes it from Ohana. Events reach the
  calendar page through `GET /families/{id}` (`events` by day, additive), so polling and
  undo stay as they were; the grid shows a dot (tooltip on desktop, a line in the selection
  bar on phones), events are read-only there (managed from the appointments page or the
  REST API `/events`). The feed shows them only with `events=1` (off by default in the
  feed settings: they name doctors and practices in a URL that works without signing in).
- **Calendar → Meals: an `away` flag per type**, independent of the role (a "Trip" may cover
  day care or not). The plan's earlier idea "covers / day off for everyone" can't be told
  from the data (roles are about day care, not about the whole family), so the family says
  it explicitly. Away days get no lunch at all: no cooking, no leftovers, no fallback; the
  number of cooking sessions follows the days at home; leftover spacing still counts
  calendar days (so leftovers may land right after a trip). Only generating / refreshing
  applies it: marking a trip later changes an existing plan after *Refresh*; a day that
  already has a meal keeps showing it. family-planner's files and API calls without `away`
  keep working (false).
- **Meals → Finance: read-only links.** The groceries category is a finance setting
  (`fin_settings.groceries_category_id`, Settings → Finance; default: the category named
  Groceries / Lebensmittel, so most families need nothing). A shopping list shows the
  transactions of that category and its subcategories on its shopping day ± 1 day with the
  finance module's net total (refunds count back, split bookings by their parts); a
  transaction in that window gets a 🛒 link to the list. **No estimated cost**: ingredients
  have no prices, so the plan's "estimated cost" isn't possible without a price list.
- **Notifications everywhere:** `notification_prefs` per family and event (on/off,
  channels; a missing row = the defaults: appointments and coverage on, shopping reminder
  off). Appointment searches keep choosing their channels; the family switch only turns them
  off. The **coverage alert** runs in the worker from `NOTIFY_HOUR` (7, server time): weekdays
  in the next 14 days with a needs-cover entry and no cover; one message listing them all,
  sent only when at least one day wasn't told before (new ones marked), at most once a day.
  The days told about are remembered and dropped once covered, so a day that loses its cover
  is told again; a failed or impossible send (no channel) retries the next day. The
  **shopping reminder** (from `SHOPPING_REMINDER_HOUR`, 18) sends tomorrow's list (what is
  still unticked) once per shopping day. Days are the server's local days (the container's
  `TZ`, Europe/Berlin in production).
- **Overview:** one dashboard instead of a card per module (the module descriptions are gone,
  a row of module links stays): today (meal or "away", the day's appointments), the next
  uncovered day, coming up (calendar runs and booked appointments together, 30 days), the
  shopping list, this month's finances, the searches' earliest finds.
- **Settings:** the General tab keeps name, members, invites and leave/delete; the home
  address and notifications (events + channels) moved to a new *Household* tab
  (`?tab=household`; links from the slot page and the search form go there). On phones the
  tabs wrap onto two rows.

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

- **Recipe generation and AI photos** came later, with phase 3 part B (see its notes): behind
  the family's AI settings instead of cookless's per-household Gemini key.
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

### Phase 3 notes, part B (tools for every module, recipe generation; deviations)

- **Tools** (`lib/assistant/tools/`): `meals.ts` — `list_recipes` (title, tags, list,
  ingredient), `get_recipe`, `save_recipe` (add or change in part; unknown ingredients are
  added to the shared list, units by abbreviation, name or alias), `get_meal_plan` (meals,
  away days, iterations, settings), `plan_meals` (`next`, `again`, `setup` only while there is
  no plan), `get_shopping_list`, `tick_shopping_items`, `add_shopping_items` (merges with an
  open item of the same ingredient and unit); `appointments.ts` — `list_appointment_searches`
  (earliest finds), `find_doctor_specialities`, `create_appointment_search`,
  `change_appointment_search`, `run_appointment_search` (queues only), `get_appointment_slot`
  (distance from home), `book_appointment_slot`; `events.ts` — `list_events`, `add_event`,
  `remove_event` (phase 7's `cal_events`; the calendar tools didn't cover them). The writing
  ones are `write: true`, so viewers and `allow_writes: false` don't get them; the lib
  functions check the chat user's role again (`ToolContext.userId`).
- **"Without fish"** is an option of one planning (`plan_meals` `excludeTags`), not a change
  of the plan's excluded tags; those recipes also stay out of the gap-fill that otherwise
  ignores excluded tags (cookless's A1 rule), so days may stay empty rather than serve fish.
- **Undo** works like the calendar's and finances': routes of the family API the client
  replays (`/meals/...`, `/appointments/searches/{id}`, `/events`). A plan change keeps a
  snapshot of the iteration it replaced (meals, shopping lists with ticks) in the undo step;
  `POST /meals/plan/restore` puts it back (refusing other families' iterations and recipes).
  Not undoable: *run now* (harmless), `setup` undoes by deleting the plan. Removing a booked
  appointment undoes into the same booking (`POST /events` with `searchId` + `resultId`).
- **Appointment searches from a sentence:** the speciality comes from Doctolib's
  autocomplete (same label, else the first; unreachable Doctolib → jameda only) and the
  offline jameda terms (a profession first); the place is the family's home address unless
  the user names one (Photon); `before` becomes `dayLimit` (days from the user's today, max
  365). New searches notify all of the family's enabled channels (the form preselects only a
  single channel). Look-ups have a 15 s timeout on top of the clients' own.
- **Recipe generation** (cookless's `lib/ai`, `app/api/recipes/generate`, `bulk-create`, the
  generate page): one chat completion with the family's model instead of Gemini's JSON mode,
  so the answer is checked with zod (`lib/meals/ai/verify.ts`: JSON found in Markdown or an
  object, numbers as text accepted, invalid recipes / ingredients / steps dropped).
  cookless's `verify.ts` (checking a Gemini key) is not ported: Settings → AI has *Test*. The
  stream runs **inline in the web process** (NDJSON, as in cookless), not in the worker: a
  user-started, watched call of 10–30 s (plus photos), with timeouts (2 min for the text,
  90 s per photo) and cancelled with the request; a job + polling would add a table for no
  gain. Default 5 recipes (cookless 10).
- **AI photos:** `POST {base}/images/generations` with `ai_settings.image_model` (`b64_json`;
  asked again without `response_format` for models that refuse it, URLs downloaded). The
  field is new in *Settings → AI*; without an image model the photo switch and the photo
  button are hidden. **Gemini:** Gemini's OpenAI-compatible images endpoint serves only Imagen
  models, so for a Gemini image model (`gemini-*`, e.g. `gemini-2.5-flash-image`, which the
  legacy import sets for cookless families) on Gemini's base URL
  (`generativelanguage.googleapis.com`) the photo comes from Gemini's native
  `models/{model}:generateContent` with `responseModalities: ["Image"]` and the family's key
  (`x-goog-api-key`), as cookless did.
- **"Assistant turn finished"** (`notification_prefs` event `assistant_turn_finished`, off by
  default): after a turn of at least `ASSISTANT_NOTIFY_AFTER_SECONDS` (30) that wasn't
  stopped, if nobody followed the chat in the last minute (`chats.seen_at`, migration
  `0007_assistant_tools`, written every 15 s by an open stream). The channels are the
  family's, so the message names the chat, not its content.
- The system prompt describes the meals (with the family's tags) and appointments (with the
  home address); the "tools come later" text is gone, and the chat panel suggests examples
  for both pages. With ~34 tools the tool list takes ~7,700 tokens of the context window.

### Phase 3 notes (the assistant, part A; deviations)

- **Code:** `lib/assistant/` — `store.ts` (the AI part of family-planner's `Store` over
  Drizzle: `ai_settings`, `chats`, `chat_items`, `chat_messages`; `ctx.assistant`),
  `routes.ts` (`handleAi`: settings, models, test, categorize, `/agent`; `prepareTurn`),
  `chat-routes.ts` (the chat routes, following a chat from the database), `chats.ts` (the
  `Runner` of a turn), `runner.ts` (the worker's `ChatRunner`), `chat.ts` (system prompt,
  `runChat`), `provider.ts`, `net.ts`, `context.ts`, `analytics.ts`, `calc.ts`,
  `categorize.ts`, `agent.ts`, and the tools by module in `tools/` (`calendar.ts`,
  `finance.ts`, `general.ts`, `web.ts`; part B adds `meals.ts` and `appointments.ts` to the
  registry in `tools/index.ts`). UI in `components/assistant/`.
- **Turns run in the worker only.** Posting a message saves it and leaves the chat *running*
  without a holder (`run_token` null); the worker looks every second (`ASSISTANT_TICK_MS`) for
  such chats, for idle chats with queued messages and for running chats whose lease ran out,
  claims each (`claimChat`) and runs it without awaiting (`ASSISTANT_MAX_CONCURRENT`, 4). The
  lease (renewed every 5 s) stays: a worker that dies leaves the turn to the next one, which
  repairs it as family-planner did (counted as a failed try). Stop and delete are noticed on
  the next tick. family-planner's hand-off between Edge Function invocations
  (`POST …/resume`, `handOffMs`, `deadlineMs`) is gone: the worker passes no time limit (a
  model call still times out after 2 minutes).
- **Following a chat** keeps family-planner's event stream (`GET …/events?since=rev`), now
  read from the database every 0.5 s; streaming text is saved every 0.5 s, so it arrives in
  pieces instead of token by token (there are no `delta` events any more).
- `POST /ai/chat` (a turn of a chat the caller keeps, run in the request) is not ported: the
  web process never runs a turn. Its tests run `runChat` directly. `POST /ai/models`,
  `/ai/test` and `/ai/categorize` still call the model in the request (short; with timeouts).
- **Viewers** chat too (family-planner's assistant was for editors only): their turns get only
  the tools that read, and the instructions say why. `GET /ai/settings` tells viewers only
  whether the assistant is set up. Settings, models, test and categorize need an editor.
- **Pages** are Ohana's (`overview`, `calendar`, `finance`, `meals`, `appointments`,
  `settings`); family-planner's `vacation` is read as `calendar`. (Until part B the
  instructions said that meals' and appointments' tools come later.)
- **Private networks:** the family's AI endpoint may be on one when `AI_ALLOW_PRIVATE_ENDPOINT`
  is set (family-planner allowed that only in development); pages and search never.
- The keys are sealed with Ohana's `SecretBox` (`ENCRYPTION_KEY`, else derived from
  `AUTH_SECRET`), so `serverReady` is always true. `ai_settings.image_model` is there for the
  recipe photos (part B). Chat times are milliseconds (`timestamp_ms`).
- `GET /api/v1/families/{id}/agent` (family-planner's instructions for AI agents) is ported;
  *Settings → AI* links it. Not ported: moving device-kept chats on first load (the route
  `POST …/chats/import` is there for the import), rate limits on AI requests (Ohana's API
  needs an account).
- After a change of the assistant (or its undo) the calendar and finance pages reload, and
  server-rendered pages refresh (`components/assistant/events.ts`).
- The transaction rows switch to their wide layout by the list's own width (a container
  query), so they keep the payee when the assistant panel is open.

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

### Phase 6 notes (the importer, parts A, B and C)

`scripts/import-legacy.ts` (`npm run import-legacy`, README → "Importing the old apps") is
complete (part A: accounts, calendar, meals, appointments; part B: family-planner's finances;
part C: the assistant). What remains of phase 6 is the rehearsal, the real import and the
cut-over.

- **Code:** `lib/import/` — `accounts.ts` merges users / families / members (stage 1), then the
  `AREAS` list in `index.ts` runs one function per source and area:
  `family-planner/{accounts,calendar,finance,assistant}.ts` (API tokens, calendar, finances,
  AI settings and chats), `cookless/{accounts,meals,assistant}.ts` (invites, meals and photos,
  the Gemini key), `fma/{accounts,appointments}.ts` (invites, channels, searches). The dry run
  lists any family-planner table no area read (none of the known ones is left;
  `auth_challenges` and `rate_limits` are ignored on purpose).
- **Assistant (part C):** `ai_settings` → `ai_settings` (`context_window` kept, `image_model`
  empty). The API and search keys are sealed with family-planner's `AI_CONFIG_KEY` (same
  `v1:` AES-GCM format as `lib/secrets.ts`): with `--family-planner-ai-secret` /
  `FAMILY_PLANNER_AI_SECRET` they are opened and sealed again with Ohana's key; without it, or
  when a key doesn't open, the settings come without it and the report lists the family under
  "AI keys to enter again" (`report.aiKeys`; a note when no key opened at all, likely the wrong
  secret). `ai_chats` / `ai_chat_items` / `ai_chat_messages` → `chats` / `chat_items` /
  `chat_messages` with ids, revisions, `context` / `notes` / `usage`, times in milliseconds;
  chats whose family or user isn't imported are skipped. **Running turns:** a chat that was
  running comes over as running *without a holder and with `stop` asked*, so the worker's
  `Runner` takes it, repairs it (tools that ran marked interrupted, told to the model) and ends
  it with "(stopped)", without calling the model, leaving a history that is valid for the
  next message (simply marking it idle could leave tool calls without results). Queued
  messages are dropped (they'd start turns long after they were written); both are noted.
  **cookless's Gemini key** (plaintext there) → `ai_settings` for a family without
  family-planner settings (those win; a skipped entry says so), only when `ai_enabled`: base
  URL `https://generativelanguage.googleapis.com/v1beta/openai/`, cookless's models
  (`gemini-2.5-flash`, image model `gemini-2.5-flash-image`), key sealed, `allow_writes` off,
  search none, `context_window` 0.
- **Finances (part B):** `family_settings` → `fin_settings` (currency; `csv_mappings` and
  `benchmark` stay JSON text), `finance_categories` → `fin_categories` (tree order, parents
  first), `finance_accounts` → `fin_accounts`, `transactions` → `fin_transactions` (bookings
  before their parts, otherwise the dump's order, which is the order within a day for rows
  created at once). Ids, transfer ids, `split_of`, import hashes and `created_at` (ms) are kept.
  A reference to a row that isn't in the dump (a parent, category, account or booking) is
  cleared and reported; family-planner's foreign keys make that unlikely.
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
  longest-standing editor's). Default finance categories (same language) only for families
  without family-planner categories, default meal tags only for families without cookless tags.
- **Not imported:** sessions, setup links, passkeys, expired / used invites, deactivated
  accounts, findmyappointment's runs, results and profile cache, messages waiting in a
  chat's queue. Searches keep `next_run_at`, so the worker runs them soon after; without the
  run history their first run notifies about everything available.

### Parity check (after phase 7)

A feature-by-feature comparison with the three apps' last `main` found only small UI gaps, now
closed: Settings → *Data* (family-planner's export / import of the family file, without
*Clone*), the theme switch (light / dark / system, per device, on the Account page; both
family-planner and cookless had one), the warning before closing the calendar while changes
are being saved (family-planner), and the collapsible sidebar (cookless; `Ctrl/⌘+B`). Left
out on purpose: joining a family by typing an invite code (cookless); Ohana's invites are
links.

## Decided

- The app lives at the repo root (no `web/`).
- Nothing is redirected: the old domains, calendar feeds included, go away with the old apps.
- After the import, the Supabase project is kept read-only for a while as an extra backup.
