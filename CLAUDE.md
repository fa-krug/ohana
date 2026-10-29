# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Ohana** is one Next.js app for a family: calendar, finance, meals, doctor appointments and an
AI assistant. It replaces `fa-krug/family-planner`, `fa-krug/cookless` and
`fa-krug/findmyappointment`; [docs/plan.md](docs/plan.md) has the decisions, what comes from
which app, and the phases. Phase 0 (accounts, families, admin, shell, worker, deploy) and
phase 5 (appointments, notification channels) are done; the other modules are placeholders
until their phase.

## Commands

```bash
npm run dev           # Next.js dev server on http://localhost:3000
npm run worker        # background worker (tsx worker/index.ts)
npm test              # Vitest (tests/*.test.ts)
npm run typecheck     # tsc --noEmit
npm run build         # production build (standalone output)
npm run db:generate   # Drizzle migration from lib/db/schema.ts changes
npm run db:migrate    # apply migrations to DATABASE_FILE (default ./data/ohana.db)
npm run setup-link -- <email>   # print a new setup link for an account
```

## Architecture

- **Stack:** Next.js 16 (App Router), React 19, TypeScript, Tailwind CSS 4, Radix primitives
  (`components/ui/`), Drizzle ORM over SQLite (`better-sqlite3`, WAL). Schema in
  `lib/db/schema.ts`, migrations in `drizzle/`.
- **Two processes, one image:** `docker-entrypoint.sh web` migrates then serves;
  `docker-entrypoint.sh worker` runs `worker/index.ts` (waits for the migrations, then loops
  every `APPT_TICK_SECONDS` (15): the appointment `SearchRunner`, and every
  `WORKER_TICK_SECONDS` (60) `lib/maintenance/cleanup.ts` and the nightly
  `lib/maintenance/backup.ts`). Long-running jobs (appointment searches, assistant turns,
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
- **Server actions** live in `app/actions/*.ts` and wrap their work in `run()`
  (`lib/actions/result.ts`), which signs in the user (and checks admin with `{ admin: true }`)
  and turns `AuthError` / `ZodError` into `{ ok: false, status, message }`.
- **UI:** `components/shell/app-shell.tsx` is the frame (left sidebar with family switcher,
  modules from `components/shell/modules.ts`, account menu; right assistant panel, `Ctrl/⌘+J`;
  both are sheets on phones). A module that isn't built yet is served by
  `app/(app)/f/[familyId]/[module]/page.tsx`; a built one gets its own folder, which wins over
  the dynamic segment; set `ready: true` in `modules.ts` then.
- **Secrets (`lib/secrets.ts`):** `SecretBox` (port of family-planner's): AES-256-GCM,
  `v1:<base64 iv+ciphertext+tag>`, keyed by `ENCRYPTION_KEY` or else HKDF(`AUTH_SECRET`,
  info "ohana-secrets"). `getSecretBox()` for channel tokens / SMTP passwords (and the AI keys
  later). Stored secrets never go back to the browser: DTOs say `hasToken`, a blank field on
  edit keeps the stored value.
- **Notifications (`lib/notifications/`), family-wide:** `notification_channels` (Pushbullet,
  Pushover, Telegram, email/SMTP; `token` sealed). `channels.ts` CRUD (editors),
  `notifyFamily(db, familyId, message, { channelIds?, send? })` in `index.ts` sends to the
  enabled channels (`channelIds: []` = none, omitted = all); a failing channel is logged and
  counted, never thrown. `send.ts` holds the network senders (untested); `locale.ts` picks the
  family's language (its longest-standing editor's). UI: `components/families/notifications-card.tsx`
  in Settings (editors only), with "Test".
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
  module from `lib/db/schema/` (`notifications.ts`, `appointments.ts`).
- **Family settings:** `FamilySettings` renders its `children` before "Leave or delete": each
  module adds its own section component there (see `settings/page.tsx`).
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
