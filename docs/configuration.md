# Configuration reference

Ohana is configured with environment variables. With the provided `docker-compose.yml` they go
into `.env` next to it ([.env.example](../.env.example)); both containers read the same file.
Only `APP_URL` and `AUTH_SECRET` are required. Developers running from source use
`server/.env` ([server/.env.example](../server/.env.example)), where the defaults below marked
*(source)* apply.

## Required

| Variable | Default | |
| --- | --- | --- |
| `APP_URL` | — | The public address with scheme, e.g. `https://ohana.example.com`. Used for links in invites, setup links and notifications; passkeys are bound to its host; cookies are `Secure` when it starts with `https://`. |
| `AUTH_SECRET` | — | A long random secret (`openssl rand -hex 32`). Signs the sign-in cookies and, unless `ENCRYPTION_KEY` is set, keys the encryption of stored secrets. The server refuses to start without it in production. **Don't change it**: stored AI keys and notification tokens would become unreadable. |

## Server

| Variable | Default | |
| --- | --- | --- |
| `ENCRYPTION_KEY` | derived from `AUTH_SECRET` | A separate key for secrets at rest (32 random bytes, base64: `openssl rand -base64 32`). Changing it makes the stored secrets unreadable. |
| `DISABLED_MODULES` | none | Modules turned off, comma list: `finance`, `meals`, `appointments`, `assistant`. The calendar is always on. See [Modules](/self-hosting#modules). |
| `PORT` | `8000` (image), `3000` (source) | The port the server listens on. |
| `HOST` | `0.0.0.0` | The address the server listens on. |
| `DATABASE_FILE` | `/app/data/ohana.db` (image), `./data/ohana.db` (source) | The SQLite database. |
| `MEDIA_ROOT` | `/app/data/media` (image), `./data/media` (source) | Recipe photos. |
| `TZ` | `Europe/Berlin` (compose) | Time zone of the daily jobs (backups, notifications). |

## Passkeys

| Variable | Default | |
| --- | --- | --- |
| `WEBAUTHN_RP_NAME` | `Ohana` | The name passkey dialogs show. |
| `WEBAUTHN_RP_ID` | `APP_URL`'s host | Only to allow more than one domain (comma list), e.g. an old domain during a move. |
| `WEBAUTHN_ORIGIN` | `APP_URL`'s origin | The same for origins (comma list). |

## Backups

| Variable | Default | |
| --- | --- | --- |
| `BACKUP_DIR` | `/app/data/backups` (image) | Where the nightly database copies go. |
| `BACKUP_KEEP` | `14` | How many to keep. |
| `BACKUP_HOUR` | `3` | From which hour (server time) the night's backup is made. |
| `WORKER_TICK_SECONDS` | `60` | How often the worker's housekeeping (cleanup, backup, daily notifications) runs. |

## Notifications

| Variable | Default | |
| --- | --- | --- |
| `NOTIFY_HOUR` | `7` | From this hour: days nobody covers in the next two weeks. |
| `SHOPPING_REMINDER_HOUR` | `18` | From this hour: tomorrow's shopping list (if the family turned the reminder on). |

## Assistant

| Variable | Default | |
| --- | --- | --- |
| `AI_ALLOW_PRIVATE_ENDPOINT` | off | `1` lets the families' AI endpoint be on a private network (Ollama, LM Studio). Web pages the assistant reads stay limited to public addresses. |
| `ASSISTANT_TICK_MS` | `1000` | How often the worker looks for chats waiting for an answer. |
| `ASSISTANT_MAX_CONCURRENT` | `4` | Answers written at once. |
| `ASSISTANT_NOTIFY_AFTER_SECONDS` | `30` | The "assistant finished" notification is only sent for answers that took longer. |

## Appointment searches

| Variable | Default | |
| --- | --- | --- |
| `APPT_TICK_SECONDS` | `15` | How often due searches (and "Run now") are picked up. |
| `APPT_MAX_CONCURRENT` | `2` | Searches running at once. |
| `APPT_REQUEST_TIMEOUT_SECONDS` | `30` | Timeout per request to Doctolib, jameda and notification services. |
| `APPT_RUN_LEASE_MINUTES` | `30` | A dead worker's search is free again after this. |
| `APPT_RUN_RETENTION_DAYS` | `30` | How long the run history is kept. |
| `SCHEDULE_JITTER_PERCENT` | `15` | ± jitter on interval schedules. |
| `DOCTOLIB_CONCURRENCY` | `5` | Practices checked in parallel within one search. |
| `PROFILE_CACHE_TTL_DAYS` | `7` | How long Doctolib profiles (visit motives, agendas) are cached. |

## Docker Compose

These are read by `docker-compose.yml` itself, not by Ohana:

| Variable | Default | |
| --- | --- | --- |
| `OHANA_VERSION` | `latest` | The image tag to run; `sha-<commit>` pins one version. See [Updating](/self-hosting#updating). |
| `OHANA_PORT` | `8000` | The host port the `ohana` container is published on. |

## Per family, in the app

Some things aren't server settings but are set by each family's editors in the app: the AI
endpoint, model and keys (*Settings → Assistant*), notification channels and which events they
get (*Settings → Household → Notifications*), the home address (distances to practices), the
currency and the CSV formats of the finances. Keys and tokens are stored encrypted and never
sent back to the app.
