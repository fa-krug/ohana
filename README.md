# Ohana

One app for the whole family: calendar, finance, meals, doctor appointments and an assistant.
Ohana replaces three apps, `family-planner`, `cookless` and `findmyappointment`, and moves
their data over. See [the plan](docs/plan.md) for why and how, and its phases for what is
there already.

## What works today (phases 0 and 5)

- **Sign in** with a **passkey** (fingerprint, face or device PIN) or an email and a
  **password**. A fresh install asks for the first account at `/setup`; it becomes the
  **administrator**.
- **Families:** the left sidebar switches between your families (or creates one). In a
  family you are an **editor** (change everything, add people) or a **viewer** (only look).
  *Settings* holds the name, the members and **invite links** (for people without an
  account: the link creates one and joins the family as editor or viewer; 7 days, once).
  A family always keeps an editor; the last member deletes it instead of leaving.
- **Modules:** Calendar, Finance, Meals and Appointments are in the sidebar and on the
  overview; those not built yet are marked *coming soon*. The right sidebar (✨,
  `Ctrl/⌘+J`) is where the assistant will live.
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

### Appointments

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

### Family settings

- **Home address** (editors set it, looked up with Photon): the origin for distances.
- **Notifications** (editors): the family's channels, used by every part of Ohana:
  **Pushbullet**, **Pushover**, **Telegram** or **email** over SMTP, each with a *Test*
  button. Tokens and passwords are stored encrypted and never shown again (leave the field
  empty when editing to keep them).

## Development

```bash
npm install
npm run db:migrate   # creates ./data/ohana.db
npm run dev          # http://localhost:3000
npm run worker       # the background worker (appointment searches, cleanup, backups), in a second terminal
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
- **worker** waits for the migrations, then runs the background jobs: the **appointment
  searches** (due ones are picked up every 15 s, at most two at a time), cleanup of expired
  tokens and invites, and the **daily backup**.

Both share the volume `ohana-data` (`/app/data`: the SQLite database and `backups/`).
Pushes to `main` run the tests, build the `linux/amd64` + `linux/arm64` image, push
`sascha384/ohana:latest` to Docker Hub and redeploy the Arcane project `ohana` (GitHub OIDC,
no deploy secret), then wait for `/api/health`. The repository needs the secrets
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.

### Secrets

Channel tokens and SMTP passwords are encrypted (AES-256-GCM) before they are stored. The
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
`ohana.db-wal` / `ohana.db-shm` next to it), start them again.
