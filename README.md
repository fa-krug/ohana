# Ohana

One app for the whole family: calendar, finance, meals, doctor appointments and an assistant.
Ohana replaces three apps, `family-planner`, `cookless` and `findmyappointment`, and moves
their data over. See [the plan](docs/plan.md) for why and how, and its phases for what is
there already.

## What works today (phase 0)

- **Sign in** with a **passkey** (fingerprint, face or device PIN) or an email and a
  **password**. A fresh install asks for the first account at `/setup`; it becomes the
  **administrator**.
- **Families:** the left sidebar switches between your families (or creates one). In a
  family you are an **editor** (change everything, add people) or a **viewer** (only look).
  *Settings* holds the name, the members and **invite links** (for people without an
  account: the link creates one and joins the family as editor or viewer; 7 days, once).
  A family always keeps an editor; the last member deletes it instead of leaving.
- **Modules:** Calendar, Finance, Meals and Appointments are in the sidebar and on the
  overview, marked *coming soon* until their phase is done. The right sidebar (✨,
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
