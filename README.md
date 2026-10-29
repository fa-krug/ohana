# Ohana

One app for the whole family: calendar, finance, meals, doctor appointments and an assistant.
Ohana replaces three apps, `family-planner`, `cookless` and `findmyappointment`, and moves
their data over. See [the plan](docs/plan.md) for why and how, and its phases for what is
there already.

## What works today (phases 0 and 1)

- **Sign in** with a **passkey** (fingerprint, face or device PIN) or an email and a
  **password**. A fresh install asks for the first account at `/setup`; it becomes the
  **administrator**.
- **Families:** the left sidebar switches between your families (or creates one). In a
  family you are an **editor** (change everything, add people) or a **viewer** (only look).
  *Settings* holds the name, the members and **invite links** (for people without an
  account: the link creates one and joins the family as editor or viewer; 7 days, once).
  A family always keeps an editor; the last member deletes it instead of leaving.
- **Modules:** Calendar, Finance, Meals and Appointments are in the sidebar and on the
  overview; Finance, Meals and Appointments are marked *coming soon* until their phase is
  done. The right sidebar (✨, `Ctrl/⌘+J`) is where the assistant will live.
- **Account:** name, email (confirmed with the password or a passkey), language (English /
  German), passkeys (add one per device, rename, delete), the password (set, change, or
  remove it to use passkeys only), *sign out other devices*, and personal **API tokens** for
  scripts and AI agents (`Authorization: Bearer ohana_…`; try `GET /api/v1/me`).
- **Administration** (admins only): *Users* creates accounts, each with a **one-time setup
  link** (7 days) that signs the person in and asks for a passkey or a password; a new setup
  link also helps with a forgotten password. *Families* creates, renames and deletes families
  and decides who is a member with which role. Being an admin doesn't open a family: admins
  add themselves as members for that.
- Password sign-in is **rate limited** (10 failures per name and 15 minutes). Sessions, API
  tokens and setup links are stored only as SHA-256 hashes.

## Calendar

The family's year at a glance (family-planner's vacation calendar): vacation, public
holidays, sick days, day-care closures.

- **Year grid** of 12 months × 31 days (on phones: one calendar per month, Monday to Sunday,
  with the type buttons in a bar at the bottom). Pick the year at the top; `?y=2027` in the
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
  iCloud, Google Calendar and others, with the types, "⚠ Not covered" warnings and notes you
  choose. Its address is the only one that works without signing in, and it opens nothing but
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

## Development

```bash
npm install
npm run db:migrate   # creates ./data/ohana.db
npm run dev          # http://localhost:3000
npm run worker       # the background worker (cleanup, backups), in a second terminal
npm test             # Vitest
npm run typecheck
```

Schema changes: edit `lib/db/schema.ts`, then `npm run db:generate` to add a migration under
`drizzle/`. Settings come from the environment, see [`.env.example`](.env.example).

Locked out? `npm run setup-link -- <email>` prints a new setup link for an account (in the
container: `docker compose exec web ./node_modules/.bin/tsx scripts/setup-link.ts <email>`).

## Deployment

One Docker image, two containers ([`docker-compose.production.yml`](docker-compose.production.yml)):

- **web** applies the database migrations at start, then serves Next.js on port 8000
  (Traefik routes `ohana.fa-krug.de` to it, on the external `gitops_default` network).
- **worker** waits for the migrations, then runs the background jobs: cleanup of expired
  tokens and invites, and the **daily backup**.

Both share the volume `ohana-data` (`/app/data`: the SQLite database and `backups/`).
Pushes to `main` run the tests, build the `linux/amd64` + `linux/arm64` image, push
`sascha384/ohana:latest` to Docker Hub and redeploy the Arcane project `ohana` (GitHub OIDC,
no deploy secret), then wait for `/api/health`. The repository needs the secrets
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.

### Backups

The worker writes a consistent copy of the database every night (after `BACKUP_HOUR`,
server time) to `/app/data/backups/ohana-YYYY-MM-DD.db` and keeps the newest `BACKUP_KEEP`
(14). That protects against mistakes, not against losing the Pi: copy the folder off the Pi
too, e.g. with a nightly `restic` or `rclone` job on the host that reads the volume
(`docker volume inspect ohana-data` shows its path).

To restore: stop both containers, replace `/app/data/ohana.db` with a backup (and delete
`ohana.db-wal` / `ohana.db-shm` next to it), start them again.
