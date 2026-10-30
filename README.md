# Ohana

One app for the whole family: calendar, finance, meals, doctor appointments and an assistant.
It comes as a **web app** with its server ([`web/`](web), Next.js) and a **native app for
iPhone, iPad and Mac** ([`apple/`](apple), SwiftUI with Liquid Glass) that signs in to the
same server. Ohana replaces three apps, `family-planner`, `cookless` and `findmyappointment`, and moves
their data over. See [the plan](docs/plan.md) for why and how, and its phases for what is
there already.

## What works today (phases 0 to 5 and 7)

- **Sign in** with a **passkey** (fingerprint, face or device PIN) or an email and a
  **password**. A fresh install asks for the first account at `/setup`; it becomes the
  **administrator**.
- **Families:** the left sidebar switches between your families (or creates one). In a
  family you are an **editor** (change everything, add people) or a **viewer** (only look).
  *Settings* holds the name, the members and **invite links** (for people without an
  account: the link creates one and joins the family as editor or viewer; 7 days, once).
  Members can also be added **without an account** (children, grandparents): just a name
  and optionally a birthday, optionally with an invite link for them; whoever accepts it
  takes their place. Members with an account can enter their birthday too (🎂; editors for
  everyone). Birthdays show in the calendar (🎂 on the day, "Mia turns 8" in its tooltip)
  and the next 30 days' on the overview. Everyone's name is offered as "who is it for" when
  marking an appointment as booked, and the assistant knows them and their ages.
  A family always keeps an editor; the last member deletes it instead of leaving.
- **Modules:** Calendar, Finance, Meals and Appointments are in the sidebar and on the
  overview; those not built yet are marked *coming soon*. The right sidebar (✨,
  `Ctrl/⌘+J`; drag its edge to make it wider; a sheet on phones) is the **assistant** (see
  below); it also has a page of its own, with the chats on the left.
- **Account:** name, email (confirmed with the password or a passkey), language (English /
  German), passkeys (add one per device, rename, delete), the password (set, change, or
  remove it to use passkeys only), *sign out other devices*, and personal **API tokens** for
  scripts and AI agents (`Authorization: Bearer ohana_…`; try `GET /api/v1/me`).
- **Administration** (admins only): *Users* creates accounts, each with a **one-time setup
  link** (7 days) that signs the person in and asks for a passkey or a password; a new setup
  link also helps with a forgotten password. *Families* creates, renames and deletes families
  and decides who is a member with which role. Being an admin doesn't open a family: admins
  add themselves as members for that.
- **Meals** (phase 4, from cookless), with tabs *Recipes*, *Plan*, *Shopping* and *Tags*:
  - **Recipes** in two lists, *Favourites* and *Want to try*: search, sort, filter by tags,
    infinite scroll. A recipe has servings, prep/cooking time, ingredients (from a shared
    German/English ingredient list; unknown ones are added), steps by hand and for a kitchen
    machine (programs with temperature, time, speed, direction; drag to reorder; ingredients
    per step), tags and a **photo** (uploaded, scaled to WebP). Share a recipe as text or
    **PDF** for any number of portions; delete with *undo*.
  - **Cook view:** one step at a time (swipe on phones), servings scale the amounts, the
    screen stays on, progress is remembered.
  - **Meal plan:** iterations of 1–3 weeks, a lunch per day picked from favourites and
    want-to-try recipes (a ratio you choose) so that recipes share ingredients, leftovers for
    the next days, tags to leave out, *refresh* and *next iteration*.
  - **Shopping lists** per shopping day (one or two per week), summed and converted units,
    grouped by aisle. Ticking items works **offline**: changes wait on the phone and are sent
    when it's back online (the meals pages are cached by a service worker).
  - **Tags** per family (dietary, protein, cuisine, meal type), with defaults.
  - Viewers see everything and can cook, but change nothing. The family overview shows
    today's meal and what's left on the shopping list. The REST API (session or API token)
    has `GET /api/v1/families/{id}/recipes`, `GET /api/v1/families/{id}/recipes/{recipeId}`
    and `POST /api/v1/families/{id}/shopping/toggle`.
  - **AI** (editors, once *Settings → AI* is set up): *Generate with AI* on the recipes page
    makes new recipes with the family's model (how many, tags they must match, extra wishes;
    they stream in, you pick which to keep and they go to *Want to try*, with photos if
    wanted). With an **image model** (*Settings → AI → Recipe photos*) a recipe's page also
    has *Generate with AI* for its photo. Without an image model the photo options are hidden.
- Password sign-in is **rate limited** (10 failures per name and 15 minutes). Sessions, API
  tokens and setup links are stored only as SHA-256 hashes.

## Calendar

The family's year at a glance (family-planner's vacation calendar): vacation, public
holidays, sick days, day-care closures.

- **Year grid** of 12 months × 31 days (on phones, or when the sidebar and the assistant leave
  it too little room: one calendar per month, Monday to Sunday, with the type buttons in a bar
  at the bottom). Pick the year at the top; `?y=2027` in the
  address opens that year.
- **Entry types per year** (new families start with *Holiday*, *Vacation* and *Sick*, named in
  the creator's language). A day can have several types. A year without types offers to copy
  them from the closest year that has some. Types are edited in *Settings → Calendar*: name,
  color, role, order, delete (with its days), copy from another year.
- **Roles and coverage:** a type that *needs cover* (e.g. "Day care closed") on a weekday
  without a type that *covers* it (e.g. "Vacation Dad") or a *day off* (e.g. "Holiday") is a
  gap: the day gets a red "!", the pill at the top counts them, and *Next gap* (or `G`) jumps
  there. The type buttons count each type's workdays (a vacation day on a holiday doesn't
  count).
- **Selecting:** click or drag (also across months), `Shift` + click extends, `Ctrl/⌘` +
  click adds single days; on touch screens tap, long-press and drag, *Range* and
  *Multi-select*. Then click a type (or press `1`–`9`) to toggle it on the selected days,
  `Del` clears them, `Ctrl/⌘+C / X / V` copy, cut and paste (also a column of type names from a
  spreadsheet), the ▪ handle repeats the selection forwards or backwards, *Skip weekends*
  leaves Saturdays and Sundays out. `Ctrl/⌘+Z / Y` undo and redo, `?` shows all shortcuts.
- **Notes:** an icon and/or a comment on days (double-click, `N` or *Icon & note*).
- **Zoom:** the slider (or `Ctrl/⌘ + / − / 0`) sets how many days fit across; it is
  remembered on the device, like *Always show weekdays* and *Skip weekends*.
- Viewers see everything but can't change anything. Changes of other family members show up
  within 15 seconds.
- **Calendar feed** (*Settings → Calendar feed*): an iCalendar subscription for Apple Calendar,
  iCloud, Google Calendar and others, with the types, "⚠ Not covered" warnings, notes and
  (if ticked, `birthdays=1`) the members' birthdays, every year, you choose. Its address is the only one that works without signing in, and it opens nothing but
  the feed; *New feed address* makes the old one stop working.
- **REST API** for scripts and AI agents, with an API token (`Authorization: Bearer ohana_…`),
  the same as family-planner's:
  - `GET /api/v1/families/{id}?year=2026` – the family with the year's types, entries and notes
  - `GET|POST /api/v1/families/{id}/types?year=…`, `PATCH|DELETE …/types/{typeId}?year=…`,
    `POST …/types/copy` `{"from": 2026, "to": 2027}`
  - `GET|POST /api/v1/families/{id}/entries` – e.g.
    `{"action": "add", "type": "vacation", "from": "2026-08-03", "to": "2026-08-14", "skipWeekends": true}`
    (actions `add`, `remove`, `set`, `clear`; several as `{"ops": [...]}`; types by id or name)
  - `GET|POST /api/v1/families/{id}/notes` – `{"icon": "🎄", "comment": "Christmas", "date": "2026-12-24"}`
  - `GET /api/v1/families/{id}/export`, `POST …/import` (family-planner's export files),
    `POST …/links` `{"link": "feed"}` (new feed address), `PATCH /api/v1/families/{id}` (rename)
  - `GET /api/v1/families/{feedId}/calendar.ics?types=vacation,holiday&gaps=1&notes=1&lang=de&name=…`
    – the public feed

## Finance

The family's money (family-planner's finances): a transactions log, accounts, nested
categories, bank statement import and overviews. Amounts are in the family's currency.

- **Transactions:** money in or out, with payee, description, note, an account and a
  **category** (new families get defaults like Groceries, Housing, Salary, named in the
  creator's language; edit them in *Settings → Finance*). Pick a month, a year or all time;
  search, filter by account, category (or *Uncategorized*) and in / out / transfers; change a
  category right in the list. Every change can be undone from its message.
- **Nested categories:** a category can have subcategories, as deep as you like (Food ›
  Groceries › Bakery); add and move them in *Settings → Finance* (the ⋯ menu of a category).
  A category's totals and its filter include its subcategories; a subcategory has the kind
  (income / expense) of its top category. Deleting a category moves its subcategories and
  transactions up to its parent.
- **Accounts:** bank accounts, cash or cards, each with an opening balance. The balances show
  above the list (click one to see only its transactions): for a past month or year at its
  end, with today's below; for the running one today's.
- **Transfers between your own accounts count as 0:** tick related transactions and
  *Combine as transfer*: they count once, by their sum (500 out and 480 in is a 20 expense).
  *Find transfers* suggests pairs (the same amount out of one account and into another, at
  most 4 days apart); *Auto-combine* combines them all at once.
- **Split bookings:** some banks list a booking (an Amazon *Splitbuchung*) and its order lines
  too. *Combine as split booking* (the largest becomes the booking): the parts count with their
  own categories, the booking only with what they leave over, so nothing counts twice and the
  balances count the booking. *Auto-combine* and the import find them by order number
  ("Bestellnr. 306-…") or the "Splitbuchung" mark.
- **Import bank statements (CSV):** the import guesses the format (UTF-8 or Windows-1252,
  separator, lines before the table, date, amount or debit / credit, payee and description
  columns, German or English numbers and dates) and shows a preview to correct it, then which
  rows are new. Rows imported before are skipped (also from overlapping statements; identical
  rows on one day stay apart). Pick the account; transfers and split bookings can be combined
  right away. The format, account and that choice are remembered per bank.
- **Overview:** income, expenses and the balance of the period; a **comparison** per month
  with the month before (a year's or all time's average completed month); the **statistic
  average** (ranges per month from e.g. a statistics office, set in *Settings → Finance*) with
  where the period is in each range; a chart per month (year, all time) and the spending or
  income per category, unfolding into subcategories. The family overview shows this month.
- Viewers see the finances read-only; the calendar feed never shows them. *Settings → Finance*
  also has the currency, the saved bank formats and *Delete all finance data*. The family
  export (`GET /api/v1/families/{id}/export`) carries the finances, and its import replaces
  them.
- **REST API** (family-planner's, with an API token; amounts in cents, negative going out):
  - `GET|DELETE /api/v1/families/{id}/finance` – currency, CSV mappings, statistic average,
    categories and accounts (with balances) / delete all finance data
  - `PATCH …/finance/settings` `{"currency", "csvMappings", "benchmark"}`
  - `GET|POST …/finance/accounts` (`?at=YYYY-MM-DD`: balances at the end of that day),
    `PATCH|DELETE …/finance/accounts/{id or name}`
  - `POST …/finance/categories`, `POST …/finance/categories/defaults` `{"lang": "de"}`,
    `PATCH|DELETE …/finance/categories/{id, name or path like "Food > Groceries"}`
  - `GET …/finance/transactions?from=&to=&account=&category=&kind=income|expense|transfer&q=&limit=&offset=`
  - `POST …/finance/transactions` `{"ops": [...]}` with actions `add`, `update`, `delete`,
    `link`, `unlink`, `split`, `unsplit`; the answer's `inverse` undoes it
  - `POST …/finance/import` `{"rows": [...], "accountId", "autoTransfers": true, "dryRun": true}`
  - `GET …/finance/transfers/suggestions?from=&to=`, `POST …/finance/transfers/auto` `{"from", "to"}`
  - `GET …/finance/summary?from=&to=` – per month and per category

## Assistant

An AI assistant in the right sidebar (✨, `Ctrl/⌘+J`; on phones the ✨ button in the top bar),
from family-planner. It works with **any OpenAI-compatible API** the family sets up in
*Settings → AI* (OpenAI, OpenRouter, Mistral, Groq, Gemini's OpenAI endpoint, a local model …).

- **Chats** are kept on the server, per person and family: the history (🕘) lists them, ✚
  starts a new one. A turn runs in the **background worker**, so it goes on when the app is
  closed and every device sees the same chat; a worker restart picks the turn up again.
  Messages written while the assistant answers wait and go next (take them back with ×);
  *Stop* ends the answer with what it did so far.
- **What it can do:** read and change the **calendar** (entries, day notes, entry types per
  year, coverage gaps) and the **finances** (transactions, categories, transfers and split
  bookings, the statistic average), count calendar days and **analyze** transactions (per
  month, category, payee …, exactly), **calculate** (statistics, trends, loans and savings),
  **search the web** (Tavily or Brave, with the family's key) and **read pages** (never on
  private networks). It **asks** with answers to click when something is unclear, and asks
  for the OK before bigger changes.
- **Meals:** search recipes (by title, tags, ingredient), read and write recipes, read the
  meal plan and plan the next weeks or plan an iteration again, also *without* some tags just
  this time ("plan next week without fish"), read the shopping list, tick items off and add
  items.
- **Appointments:** list the searches with their earliest finds, create one ("find a
  dermatologist before June": speciality from Doctolib / jameda, around the home address or
  a place you name, up to the day you say), change, turn on or off, *run now*, read a slot
  (with the distance from home) and mark it as booked (a calendar event). It can't book with
  the practice. Plus the calendar's timed events: list, add, remove.
- **Every change can be undone** from the chat (*Undo*); the assistant hears about it.
  (Not: *run now*, and a booked slot's removal undoes as an event again.)
- **Notification** (Settings → Household, off by default): *Assistant finished* tells the
  family's channels when the assistant worked on something for 30 seconds or more
  (`ASSISTANT_NOTIFY_AFTER_SECONDS`) and the chat wasn't open anywhere.
- Attach **images** (screenshots, photos, shrunk in the browser) and **text files** (CSV, JSON …).
- Long chats are **condensed** for the model before they no longer fit its context window
  (the bar under the box shows how full it is).
- A chat belongs to the page it started on (calendar, finance, settings …) and keeps to that
  topic; *Move to …* takes it along to another page.
- **Viewers** can chat too, but the assistant only reads for them. Without settings the panel
  points editors to *Settings → AI* and tells viewers to ask an editor.
- *Settings → AI* (editors): API URL (with presets), key (stored encrypted, only its last four
  characters are shown), model (*Load models* asks the API), context window, *Test*, the
  image model for recipe photos (e.g. `gpt-image-1`; with Google's Gemini API
  `gemini-2.5-flash-image` works too), web search provider and key, *Allow changes*. A model on the home network (e.g. Ollama) needs
  `AI_ALLOW_PRIVATE_ENDPOINT=1` on the server.
- **Auto-categorize** (*Finance → Transactions*, editors): sorts the period's uncategorized
  transactions like similar earlier ones, the rest with the AI (it may look up unknown payees
  on the web); the CSV import can do the same for the new rows. Undo from the message.
- **REST API** (session or API token): `GET|PUT /api/v1/families/{id}/ai/settings`,
  `POST …/ai/models`, `POST …/ai/test`, `POST …/ai/categorize` `{"ids"} | {"from", "to", "skip"}`,
  the chats under `…/ai/chats` (list, start, `GET {chat}`, `GET {chat}/events?since=rev`
  (server-sent events), `messages`, `queue`, `unqueue`, `answer`, `stop`, `undone`, `page`,
  `import`), and `GET /api/v1/families/{id}/agent`: instructions for other AI agents that use
  the API with your token (Markdown). The assistant's undo uses
  `PATCH|DELETE …/meals/recipes/{id}`, `POST …/meals/shopping/check`,
  `PATCH|DELETE …/meals/shopping/items/{id}`, `POST …/meals/plan/restore`, `DELETE …/meals/plan`
  and `PATCH|DELETE …/appointments/searches/{id}` (editors). Recipes are generated with
  `POST …/recipes/generate` (NDJSON stream; editors).

## Appointments

*Appointments* watches **Doctolib** and **jameda** (one or both per search) for a speciality
near a place and tells the family when an appointment frees up (it replaces
findmyappointment).

- **Searches:** name, place (any address, looked up with Photon), Doctolib speciality and
  insurance (public / private), jameda speciality, treatment or condition (with insurance
  type, child-friendly and video-consultation filters), how many days ahead, how many result
  pages, and the schedule: every N minutes, hourly, daily (with a little random jitter) or a
  cron expression. The list shows each search with its latest results (earliest appointment
  per doctor) and refreshes itself.
- **Run now** queues the search; the worker starts it within seconds. Searches run in the
  background worker on their schedule, never in the web server.
- **Appointment page:** doctor, practice, reason for the visit, address and the **distance
  from home**, with *Book* (opens Doctolib / jameda), *Search on Google* and *Ignore* (skips
  that doctor with that reason for the visit in this search; *Show again* on the search page).
- **History:** every run with what it found (or why it failed), kept 30 days.
- **Notifications** go to the channels chosen per search, and only when something changed: a
  doctor newly available or earlier than before; or, with *only notify when earlier than the
  earliest seen so far*, only when the all-time earliest is beaten. A notification about one
  appointment opens its page in Ohana; emails list every new appointment with both links.

Viewers see all of this but can't change anything.

## How the modules work together

- **Overview:** one dashboard: *today* (the day's meal, or "away"; booked appointments of
  the day), the next uncovered day, what's *coming up* in the next 30 days (calendar entries
  and booked appointments together), the shopping list, this month's finances and the latest
  finds of the appointment searches; a row of links to the modules on top.
- **Appointments → Calendar:** on an appointment's page, editors *Mark as booked* after
  booking it with the practice: date and time (the slot's, changeable), for whom, a note, and
  optionally *Stop watching this search*. It shows in the calendar as a dot on its day (the
  time and doctor in the tooltip, on phones below the selected day), on the overview, under
  *Booked appointments* on the appointments page (with *Remove*), and, if the feed is
  subscribed with *Booked appointments (with time)* (`events=1`), as a timed event in the
  calendar feed. REST: `GET/POST /api/v1/families/{id}/events`,
  `DELETE /api/v1/families/{id}/events/{eventId}` (`{"date", "start": "HH:MM", "end",
  "title", "location", "person", "note", "url"}`).
- **Calendar → Meals:** tick *Away* next to a calendar type (Settings → Calendar), e.g. a
  "Trip" type: on its days the whole family is away, the meal plan plans no meals for them
  (when generated or refreshed) and shows them as *Away · Trip*.
- **Meals → Finance:** a shopping list shows what was *spent*: the transactions of the
  groceries category (with its subcategories) on its shopping day ± 1 day. In Finance, such a
  transaction gets a 🛒 link to that list. The category is *Settings → Finance → Groceries*
  (automatic: the category named Groceries / Lebensmittel).
- **Notifications** (Settings → Household → *What Ohana tells you*): per event on/off and
  which channels: *Appointment found* (the channels come from each search), *Day without
  cover* (each morning, weekdays in the next two weeks that need cover and have none; one
  message, and only when a day is new – the same days aren't told again), *Shopping reminder*
  (off by default; the evening before a shopping day, what is still on the list), *Assistant
  finished* (off by default; see Assistant).
- **The assistant everywhere:** its tools reach the calendar, finances, meals and appointment
  searches, so one chat can plan next week's meals without fish or set up a search for a
  dermatologist before June.

## Family settings

Tabs, kept in the address (`?tab=`): *General* (name, members, invite links), *Household*,
*Calendar*, *Calendar feed*, *Finance*.

- **Household → Home address** (editors set it, looked up with Photon): the origin for
  distances.
- **Household → Notifications** (editors): which events are sent (see above) and the
  family's channels, used by every part of Ohana: **Pushbullet**, **Pushover**, **Telegram**
  or **email** over SMTP, each with a *Test* button. Tokens and passwords are stored
  encrypted and never shown again (leave the field empty when editing to keep them).

## The iPhone, iPad and Mac app

[`apple/`](apple) is a native SwiftUI app (iOS 26, macOS 26 and later) with the same modules:
the overview, calendar, finance, meals, appointments, the assistant (an inspector on the
right, `⌘J`; a sheet on iPhone) and the family's settings. It keeps no data of its own: every
screen reads and writes the server's API. To sign in, enter the server's address: the app
opens the server's sign-in page in the system browser (passkeys work), you confirm "Connect
the Ohana app", and the app gets its own API token. It is listed on the web account page as
"<device> (app)" and can be removed there; *Sign out* in the app removes it as well. What the
app leaves to the web (passkeys, password, API tokens, administration) opens in the browser
from the app's account screen. Links to a family's pages (`https://<server>/f/…`, e.g. from a
notification, or `ohana://f/…`) open the same place in the app. Building it: see
[apple/README.md](apple/README.md); `.github/workflows/apple.yml` tests and builds it on every
change under `apple/`.

## Development

The web app and server live in [`web/`](web); run its commands there:

```bash
cd web
npm install
npm run db:migrate   # creates ./data/ohana.db and loads the units + ingredients (db:seed)
npm run dev          # http://localhost:3000
npm run worker       # the background worker (assistant turns, appointment searches, daily notifications, cleanup, backups), in a second terminal
npm run mock-ai      # a scripted stand-in AI on http://localhost:4011/v1 (model mock-large) to try the
                     # assistant without a key: run web and worker with AI_ALLOW_PRIVATE_ENDPOINT=1
npm test             # Vitest
npm run typecheck
```

Schema changes: edit `web/lib/db/schema.ts`, then `npm run db:generate` to add a migration under
`web/drizzle/`. Settings come from the environment, see [`web/.env.example`](web/.env.example).

Locked out? `npm run setup-link -- <email>` prints a new setup link for an account (in the
container: `docker compose exec web ./node_modules/.bin/tsx scripts/setup-link.ts <email>`).

## Deployment

One Docker image (built from [`web/`](web)), two containers
([`docker-compose.production.yml`](docker-compose.production.yml)):

- **web** applies the database migrations and the seed data (units, ingredients) at start,
  then serves Next.js on port 8000
  (Traefik routes `ohana.fa-krug.de` to it, on the external `gitops_default` network).
- **worker** waits for the migrations, then runs the background jobs: the **assistant's
  chat turns** (looked for every second, at most four at a time), the **appointment
  searches** (due ones are picked up every 15 s, at most two at a time), cleanup of expired
  tokens and invites, and the **daily backup**.

Both share the volume `ohana-data` (`/app/data`: the SQLite database, `media/` with the
recipe photos (`MEDIA_ROOT`) and `backups/`).
Pushes to `main` run the tests, build the `linux/amd64` + `linux/arm64` image, push
`sascha384/ohana:latest` to Docker Hub and redeploy the Arcane project `ohana` (GitHub OIDC,
no deploy secret), then wait for `/api/health`. The repository needs the secrets
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.

### Secrets

Channel tokens, SMTP passwords and the AI and search keys are encrypted (AES-256-GCM) before
they are stored. The
key is `ENCRYPTION_KEY` (32 random bytes, `openssl rand -base64 32`) if set, else one derived
from `AUTH_SECRET`, so nothing new has to be configured. Changing it (or `AUTH_SECRET`
without an `ENCRYPTION_KEY`) makes the stored tokens unreadable, and they have to be entered
again; a restored backup needs the key it was made with.

### Backups

The worker writes a consistent copy of the database every night (after `BACKUP_HOUR`,
server time) to `/app/data/backups/ohana-YYYY-MM-DD.db` and keeps the newest `BACKUP_KEEP`
(14). That protects against mistakes, not against losing the Pi: copy the folder off the Pi
too, e.g. with a nightly `restic` or `rclone` job on the host that reads the volume
(`docker volume inspect ohana-data` shows its path).

To restore: stop both containers, replace `/app/data/ohana.db` with a backup (and delete
`ohana.db-wal` / `ohana.db-shm` next to it), start them again. The backups hold the database
only: copy `/app/data/media` (recipe photos) off the Pi along with `backups/`.

## Importing the old apps

`web/scripts/import-legacy.ts` copies family-planner, cookless and findmyappointment into an
**empty** Ohana database, once, in one transaction (all or nothing). Run it with `--dry-run`
first: it does the whole import, rolls it back and prints what it would do (in `web/`):

```bash
npm run import-legacy -- --family-planner family-planner.sql \
  --cookless cookless.db --cookless-media media --fma findmyappointment.db \
  --map import-map.json [--family-planner-ai-secret <base64>] [--dry-run] [--force] \
  [--report report.json]
```

`--family-planner`: a `pg_dump --data-only` of family-planner's Supabase `public` schema;
`--cookless` / `--cookless-media`: cookless's SQLite file and its media folder (recipe photos);
`--fma`: findmyappointment's SQLite file; `--map`: which households are which family;
`--family-planner-ai-secret` (or `FAMILY_PLANNER_AI_SECRET`): family-planner's `AI_CONFIG_KEY`
(the Supabase secret its AI keys are encrypted with), so the families' AI and search keys come
over. The target is `DATABASE_FILE` (migrated), photos go to `MEDIA_ROOT`.

Every source is optional. What moves:

| From              | What                                                                                                                                                                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| all three         | **Accounts**, merged by lowercased email: name from family-planner, admin if admin in family-planner or `is_staff` in cookless / findmyappointment, the password hash of family-planner, else cookless, else findmyappointment (all work in Ohana) |
| all three         | **Families**: `import-map.json` joins a family-planner family with a cookless and a findmyappointment household; unmapped ones become families of their own, unless the map's `skip` leaves them out. Members are combined, **editor wins** over viewer (OWNER and MEMBER are editors) |
| family-planner    | family `id`, name, `feed_id`, `legacy_id`; the **calendar** (types per year, entries, notes); the **finances** (currency, CSV mappings, statistic average, category tree, accounts, transactions with transfers, split bookings and import hashes); **API tokens** as they are (same SHA-256), so scripts keep working; the **assistant**: AI settings (keys re-encrypted with Ohana's key) and everyone's **chats** |
| cookless          | tags, recipes with steps and **photos** (copied into `MEDIA_ROOT`), meal plans, shopping lists; open invite codes; the household's **Gemini key** as the family's AI settings when family-planner has none for it |
| findmyappointment | the **home address**, notification channels (tokens encrypted with Ohana's key), searches with their channels and ignore lists; open invite codes                                                                                        |

Not moved: sessions and setup links (everyone signs in again), **passkeys** (bound to the old
domains: everyone adds one at the first sign-in), expired or used invites, deactivated cookless
/ findmyappointment accounts, findmyappointment's run history and results (the first runs in
Ohana notify about what is available then), messages that waited in a chat's queue.

- **AI keys:** with `--family-planner-ai-secret` family-planner's API and search keys are
  decrypted and encrypted again with Ohana's key. Without it, or for a key that doesn't open
  with it, the settings come over without that key: the report lists those families under
  "AI keys to enter again" (Settings → AI).
- **cookless's Gemini key** (only where AI was on in cookless, only for families without
  family-planner AI settings, which win) becomes Gemini's OpenAI-compatible endpoint
  (`https://generativelanguage.googleapis.com/v1beta/openai/`, model `gemini-2.5-flash`, image
  model `gemini-2.5-flash-image` for recipe photos), no web search, and the assistant may only
  read until an editor allows changes in Settings → AI.
- **Chats** keep their history. A chat whose answer was still running when family-planner was
  dumped is ended as stopped by the worker (no model call); it is named in the report.

- Families that come from family-planner keep their calendar and finances exactly; the others
  get the preset types, as a new family does. Families without family-planner finance
  categories get the default categories (in the family's language), families without cookless
  tags the default meal tags.
- A password is **not** carried over when it is a temporary one the user never changed
  (family-planner's `admin` / `admin`, cookless's `CHANGE_PASSWORD` step) or one of the known
  defaults `admin` / `password` (findmyappointment's Django import gave everyone `password`).
  Accounts without a password are listed at the end of the report: give each one a setup link
  (`npm run setup-link -- <email>`). Everyone else signs in with their old password and is
  offered a passkey.
- The import refuses a database that has accounts or families, unless `--force` (then an
  account whose email exists is kept as it is and only gets the memberships). It also refuses
  when the families it would create exist already, so running it twice fails cleanly, even
  with `--force`.
- `import-map.json` (ids from the dry run's family list); `skip` (optional) lists families and
  households that aren't imported at all, their rows are reported as skipped:

  ```json
  { "families": [
      { "familyPlanner": "<family-planner family id>", "cookless": "<household id>", "fma": "<household id>" }
    ],
    "skip": [ { "familyPlanner": "<family-planner family id>" } ] }
  ```

### On the Pi

1. **Ohana is deployed** and has started once (so its database is migrated and seeded). Don't
   create an account at `/setup` (otherwise use `--force`).
2. **Copy cookless and findmyappointment out of their containers.** Stop them first, so the
   SQLite files are complete and nothing changes after the copy (for a rehearsal, start them
   again afterwards):

   ```bash
   mkdir -p ~/ohana-import && cd ~/ohana-import
   docker stop cookless findmyappointment
   docker cp cookless:/app/data/. ./cookless/              # cookless.db (+ -wal/-shm) and media/
   docker cp findmyappointment:/app/data/. ./fma/          # findmyappointment.db
   docker start cookless findmyappointment                 # rehearsal only
   ```

   (The data also lies in their volumes, `cookless_data` and `findmyappointment-data` in their
   compose files, prefixed with the project name: `docker volume ls`, `docker volume inspect`.)
3. **Dump family-planner** from Supabase. Take the connection string from the Supabase
   dashboard (*Connect* → *Session pooler*, which works over IPv4) and use a `pg_dump` at least
   as new as the server (the `postgres:17` image has one, also for arm64):

   ```bash
   docker run --rm -v "$PWD:/out" postgres:17 pg_dump \
     "postgresql://postgres.<project-ref>:<password>@<region>.pooler.supabase.com:5432/postgres" \
     --data-only --schema=public --no-owner --no-privileges -f /out/family-planner.sql
   ```

   pg_dump's default COPY format is what the import reads best; `--column-inserts` works too
   (a plain `--inserts` dump has no column names and is refused).
4. **Dry run** inside Ohana's image, with Ohana's environment (its `AUTH_SECRET` /
   `ENCRYPTION_KEY` encrypt the channel tokens and AI keys). Get family-planner's
   `AI_CONFIG_KEY` (where it was set with `supabase secrets set`; Supabase doesn't show it
   again, so from your password manager), `export FAMILY_PLANNER_AI_SECRET=…` in the shell
   (`-e FAMILY_PLANNER_AI_SECRET` below passes it in, and also to the real import); without it
   the AI keys are entered again afterwards. In the Arcane project's folder on the Pi (the
   one with Ohana's compose file and `.env`, e.g. `/home/pi/docker/ohana`; add `-f <file>` if
   the compose file has another name):

   ```bash
   docker compose run --rm --no-deps -v ~/ohana-import:/import -e FAMILY_PLANNER_AI_SECRET web \
     ./node_modules/.bin/tsx scripts/import-legacy.ts \
     --family-planner /import/family-planner.sql \
     --cookless /import/cookless/cookless.db --cookless-media /import/cookless/media \
     --fma /import/fma/findmyappointment.db --dry-run
   ```

   Read the family list, write `~/ohana-import/import-map.json`, and run the dry run again with
   `--map /import/import-map.json` until the report looks right (families, members and roles,
   accounts without a password, skipped rows, missing photos, AI keys to enter again).
5. **The real import**, with the old apps stopped for good (copy their data again, step 2
   without the `docker start`, and dump family-planner again, step 3, once nobody changes it
   any more) and Ohana stopped:

   ```bash
   docker compose stop web worker
   docker compose run --rm --no-deps -v ~/ohana-import:/import -e FAMILY_PLANNER_AI_SECRET web \
     ./node_modules/.bin/tsx scripts/import-legacy.ts … --map /import/import-map.json --report /import/report.json
   docker compose up -d
   ```

6. **Check**: sign in with an old password (Ohana offers a passkey), open each family's
   calendar, recipes (with photos), plan, shopping list and searches; send a *Test* from
   Settings → Notifications; enter the AI keys the report lists under "AI keys to enter
   again" (Settings → AI, then *Test*) and open an old chat; make the setup links the report lists
   (`docker compose exec web ./node_modules/.bin/tsx scripts/setup-link.ts <email>`);
   re-subscribe calendar feeds from Settings → Calendar feed (the old feed URLs go away with
   family-planner). If something is wrong: stop Ohana, delete `ohana.db*` and `media/recipes`
   in the volume, start it (it migrates an empty database), fix the map and import again.
