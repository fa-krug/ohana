# Quick start

From nothing to your family's first calendar entry in about ten minutes. You need:

- A machine that runs **Docker with Compose**: a Raspberry Pi 4, a NAS, a small VPS or the
  computer you're reading this on.
- For the family's phones: a **domain name with HTTPS** pointing at that machine. Passkeys only
  work over HTTPS. Just trying it out? Skip that and use [the local variant](#just-trying-it-out).
- The **Ohana app** on an iPhone, iPad or Mac (to build it yourself, see
  [apple/README.md](../apple/README.md)).

## 1. Get the files

```bash
mkdir ohana && cd ohana
curl -O https://raw.githubusercontent.com/fa-krug/ohana/main/docker-compose.yml
curl -o .env https://raw.githubusercontent.com/fa-krug/ohana/main/.env.example
```

`docker-compose.yml` runs two containers from one image (`ghcr.io/fa-krug/ohana`, for amd64
and arm64): `ohana`, the API on port 8000, and `ohana-worker`, the background jobs. Both share
the volume `ohana-data` with the database, photos and backups.

## 2. Set the two required settings

Open `.env` and set:

- `APP_URL`: the address your family will use, e.g. `https://ohana.example.com`.
- `AUTH_SECRET`: a long random secret. Keep it safe and never change it: it also encrypts the
  stored AI keys and notification tokens.

Or let the shell do it (works on Linux and macOS):

```bash
perl -pi -e 's|^APP_URL=.*|APP_URL=https://ohana.example.com|' .env
perl -pi -e "s|^AUTH_SECRET=.*|AUTH_SECRET=$(openssl rand -hex 32)|" .env
```

Everything else is optional; the [configuration reference](/configuration) lists it all.

## 3. Start Ohana

```bash
docker compose up -d
curl http://localhost:8000/api/health   # → {"status":"ok"}
```

The `ohana` container applies the database migrations at every start; `ohana-worker` waits for
it. `docker compose logs -f` shows what they do.

## 4. Put HTTPS in front

Point your domain at the machine and let a reverse proxy terminate TLS and forward to port 8000.
With [Caddy](https://caddyserver.com), which gets the certificate itself, the whole `Caddyfile`
is:

```
ohana.example.com {
    reverse_proxy localhost:8000 {
        flush_interval -1
    }
}
```

nginx and Traefik: see [Reverse proxy](/self-hosting#reverse-proxy).

## 5. Create the first account

Open `https://ohana.example.com/setup` and create your account with a passkey or a password.
The first account is the **administrator**. (You can also skip this and enter the address in the
app right away: on a fresh server it opens the same setup.)

## 6. Connect the app

1. Open the Ohana app. Without a server it shows a read-only demo family to look around in.
2. Tap **Connect your Ohana server** (in the banner above the demo) and enter
   `ohana.example.com`.
3. Sign in on the page that opens (passkeys work there) and confirm **Connect**. The app gets
   its own token; you can remove it later under *Settings → Account*.

## 7. Create your family and invite the others

In the app, create your family. Under *Settings → Household → Members* add the others: an **invite link**
creates their account and adds them in one go. Children and grandparents without an account are
added as people, with their birthdays.

That's it. Where to go from here:

- **AI:** *Settings → Assistant* in the app, with any OpenAI-compatible endpoint, or your own model
  ([details](/self-hosting#the-assistant-and-ai)).
- **Notifications:** *Settings → Household → Notifications* (Pushover, Pushbullet, Telegram,
  email, ntfy).
- **Modules you don't need:** `DISABLED_MODULES=appointments` in `.env`
  ([details](/self-hosting#modules)).
- **Backups and updates:** [Backups](/self-hosting#backups), [Updating](/self-hosting#updating).

## Just trying it out

On your Mac (or any machine you'll use the app from), without a domain:

```bash
mkdir ohana && cd ohana
curl -O https://raw.githubusercontent.com/fa-krug/ohana/main/docker-compose.yml
curl -o .env https://raw.githubusercontent.com/fa-krug/ohana/main/.env.example
perl -pi -e 's|^APP_URL=.*|APP_URL=http://localhost:8000|' .env
perl -pi -e "s|^AUTH_SECRET=.*|AUTH_SECRET=$(openssl rand -hex 32)|" .env
docker compose up -d
```

Then connect the Mac app to `http://localhost:8000` and create the first account with a
password. To reach it from a phone on the same network, use the machine's address instead
(`APP_URL=http://192.168.1.20:8000`, the same in the app). Passkeys need HTTPS on a real domain,
so sign in with a password there.

To start over: `docker compose down -v` removes the containers **and all data**.

## Something doesn't work?

- **Passkeys fail:** `APP_URL` must be exactly the address in the browser, scheme and host,
  over HTTPS.
- **The app says the server is too old:** `docker compose pull && docker compose up -d`.
- **Locked out:** `docker compose exec ohana ./docker-entrypoint.sh setup-link you@example.com`
  prints a new setup link.
- More in [Troubleshooting](/self-hosting#troubleshooting), or
  [open an issue](https://github.com/fa-krug/ohana/issues).
