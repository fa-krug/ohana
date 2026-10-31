# Self-hosting Ohana

Ohana runs as two containers from one image, sharing one volume:

- **`ohana`** serves the API and the sign-in pages on port 8000. At every start it applies
  the database migrations and loads the shared units and ingredients.
- **`ohana-worker`** runs the background jobs: assistant answers, appointment searches,
  the daily notifications, cleanup and the nightly backup. It waits until `ohana` has migrated.
- **`/app/data`** (the volume) holds the SQLite database `ohana.db`, `media/` (recipe photos)
  and `backups/`.

A Raspberry Pi 4 or any small VPS is enough. Images are published for `linux/amd64` and
`linux/arm64` at `ghcr.io/fa-krug/ohana`.

## Requirements

- Docker with Compose.
- A **domain name with HTTPS**. Passkeys only work over HTTPS on the domain in `APP_URL`, and
  the app talks to the server over the internet or your network. A reverse proxy (Caddy,
  Traefik, nginx) terminates TLS and forwards to port 8000. On a home network without a
  domain, password sign-in over plain HTTP works, but passkeys don't.

## Install

```bash
mkdir ohana && cd ohana
curl -O https://raw.githubusercontent.com/fa-krug/ohana/main/docker-compose.yml
curl -o .env https://raw.githubusercontent.com/fa-krug/ohana/main/.env.example
```

Edit `.env`:

| Setting | |
| ------- | - |
| `APP_URL` | **Required.** The public address, e.g. `https://ohana.example.com`. Links in invites and notifications use it, passkeys are bound to its host, cookies are `Secure` when it starts with `https://`. |
| `AUTH_SECRET` | **Required.** A long random secret: `openssl rand -hex 32`. Keep it safe and don't change it (see *Secrets*). |
| `ENCRYPTION_KEY` | Optional key for stored secrets (`openssl rand -base64 32`); else derived from `AUTH_SECRET`. |
| `DISABLED_MODULES` | Optional: `finance`, `meals`, `appointments`, `assistant` (comma list). |
| `AI_ALLOW_PRIVATE_ENDPOINT` | `1` to allow an AI endpoint on your own network (Ollama, LM Studio). |
| `TZ` | Time zone of the daily jobs (in `docker-compose.yml`, default `Europe/Berlin`). |
| `OHANA_VERSION` | Image tag to run (in `docker-compose.yml`, default `latest`; `sha-<commit>` pins one version). |

Every other setting (backup hour, notification hours, appointment search limits, …) is listed
with its default in [server/.env.example](../server/.env.example).

Start it:

```bash
docker compose up -d
docker compose logs -f ohana
```

## Reverse proxy

Forward your domain to the `ohana` container's port 8000. Long-lived responses (the assistant's
answers are streamed) must not be buffered.

**Caddy** (gets certificates itself):

```
ohana.example.com {
    reverse_proxy localhost:8000 {
        flush_interval -1
    }
}
```

**nginx:**

```nginx
server {
    listen 443 ssl;
    server_name ohana.example.com;
    # ssl_certificate …; ssl_certificate_key …;
    client_max_body_size 20m;   # recipe photos, finance imports
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_read_timeout 1h;
    }
}
```

**Traefik:** drop the `ports:` of the `ohana` service, put it on Traefik's network and add
labels like `traefik.http.routers.ohana.rule=Host(\`ohana.example.com\`)` and
`traefik.http.services.ohana.loadbalancer.server.port=8000`
([docker-compose.production.yml](../docker-compose.production.yml) is a working example).

## First run

1. Open `https://ohana.example.com/setup` and create the first account (a passkey or a
   password). It is the **administrator**. Or enter the server's address in the app: on a fresh
   server it opens the same setup and connects right after.
2. In the app, create your family. Invite the others from *Settings → Household* (an invite
   link creates their account), or, as administrator, create accounts under *Administration*:
   each gets a one-time **setup link**.
3. Locked out (forgotten password, lost passkey)? Print a new setup link:

   ```bash
   docker compose exec ohana ./docker-entrypoint.sh setup-link you@example.com
   ```

## The app

The family uses the app for iPhone, iPad and Mac. Enter the server's address, sign in in the
sheet that opens (passkeys work there), confirm *Connect*, and the app gets its own API token
(remove it any time under *Account → API tokens* in the app). Building and distributing the
app yourself: [apple/README.md](../apple/README.md).

Links in notifications (`https://ohana.example.com/f/…`) open a page with an *Open the app*
button, which opens the same place in the app.

## Modules

Every module is on by default. Turn off what your family doesn't use, e.g. the appointment
searches (Doctolib and jameda, Germany only) elsewhere:

```
DISABLED_MODULES=appointments
```

A turned-off module disappears from the app, its API answers 404, the worker skips its jobs and
the assistant loses its tools. Its data stays in the database; removing the setting brings it
back. The calendar is always on.

## The assistant and AI

AI is set up per family in the app (*Settings → Assistant*): any **OpenAI-compatible** endpoint with
its key and model (OpenAI, Anthropic's or Google's OpenAI-compatible endpoints, OpenRouter, …),
optionally an image model for recipe photos and a web search key (Tavily or Brave). Keys are
stored encrypted.

To keep everything at home, run a local model with **Ollama** or LM Studio and set
`AI_ALLOW_PRIVATE_ENDPOINT=1`, then use e.g. `http://192.168.1.10:11434/v1` as the endpoint.
Without that setting Ohana refuses endpoints on private addresses. Pages the assistant reads
on the web are always limited to public addresses.

## Notifications

Channels are set per family in the app (*Settings → Household → Notifications*): Pushover,
Pushbullet, Telegram, email over SMTP, or **ntfy**. For ntfy, enter the topic URL (on
`ntfy.sh` or your own ntfy server, e.g. `https://ntfy.example.com/family`) and, for a
protected topic, an access token; subscribe to the topic in the ntfy app. *Settings → Household
→ What Ohana tells you* chooses which events go where.

The server can't send Apple push notifications itself (that needs the app developer's key), so
the app's own notifications go through these channels.

## Backups

The worker writes a consistent copy of the database every night (after `BACKUP_HOUR`, default
3) to `backups/ohana-YYYY-MM-DD.db` in the volume and keeps the newest `BACKUP_KEEP` (14).
That protects against mistakes, not against losing the machine: copy the volume's `backups/`
**and `media/`** (recipe photos) elsewhere, e.g. with restic or rclone on the host
(`docker volume inspect ohana_ohana-data` shows its path).

To restore: `docker compose stop`, replace `ohana.db` in the volume with a backup (and delete
`ohana.db-wal` / `ohana.db-shm` next to it), `docker compose start`. A restored database needs
the same `AUTH_SECRET` / `ENCRYPTION_KEY` it was made with, or the stored AI keys and channel
tokens have to be entered again.

## Updating

```bash
docker compose pull && docker compose up -d
```

Migrations run when `ohana` starts. Every change that lands on `main` and passes the tests is
published right away, there are no separate releases. Image tags:

- `latest` (and `main`, the same): the newest version.
- `sha-<commit>` (e.g. `sha-56275e0`): one exact version, to pin it or go back (set
  `OHANA_VERSION=sha-56275e0` in `.env`). `/api/v1/server` shows the running version as
  `<version>+<commit>`.

Before updating, glance at the commits since your version on GitHub. Going back to an older
image after a database migration isn't supported: restore a backup instead. The app checks the server's API version and asks
you to update the server when it's too old; the server's API only grows, so older apps keep
working with newer servers.

## Secrets

Notification tokens, SMTP passwords and AI / search keys are encrypted (AES-256-GCM) with
`ENCRYPTION_KEY`, or a key derived from `AUTH_SECRET`. Changing that key makes them
unreadable: they have to be entered again. Sessions, API tokens and setup links are stored only
as SHA-256 hashes; passwords as argon2id.

## Troubleshooting

- **Passkeys fail:** `APP_URL` must be exactly the address in the browser (scheme and host),
  over HTTPS. To allow a second domain, set `WEBAUTHN_RP_ID` and `WEBAUTHN_ORIGIN` (comma
  lists).
- **The app says the server is too old:** pull the newest image.
- **Health:** `curl https://ohana.example.com/api/health` → `{"status":"ok"}`;
  `/api/v1/server` shows the version and the modules that are on.
