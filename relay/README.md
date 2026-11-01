# Ohana push relay

Apple delivers notifications to an app only through APNs, and APNs only takes a push for the
app's bundle id when it is signed with an auth key of the team that owns it. That key can't be
in the open-source server or with self-hosters. So fa-krug runs this small relay: it holds the
key, and every self-hosted Ohana server sends its pushes through it (like Nextcloud's,
Bitwarden's or Matrix's Sygnal).

**The relay never sees what a notification says.** The app makes a key per device and gives it
only to its own server; the server encrypts, the app's Notification Service Extension decrypts
on the device. The relay and Apple see the device token, the sending server's IP, when, and how
big. The relay builds the APNs request itself, so a server can't put text of its own on a lock
screen: the visible text is the app's `PUSH_FALLBACK` string ("New notification from Ohana"),
shown only when the extension can't decrypt.

```
 app ── POST /v1/register {APNs token} ──▶ relay ─── relayToken ──▶ app
 app ── PUT /api/v1/me/push {relayToken, key} ──▶ its server
 server (worker) ── POST /v1/send {relayToken, ciphertext} ──▶ relay ──▶ APNs ──▶ device
                                                    the extension decrypts and shows it ◀──┘
```

It is **stateless**: no database, only its secrets and rate limits in memory (one instance;
limits don't need to survive a restart). It logs no tokens and no payloads, only APNs errors
(status and reason) and hourly counters. License: AGPL-3.0, like the server.

fa-krug's relay runs at `https://ohana-push.fa-krug.de`. The plan behind it is in
[docs/plan.md](../docs/plan.md) (phase 9).

## Protocol

All bodies are JSON. Errors are `{ "error": "…" }`. Bodies over 64 KB get 413.

### `POST /v1/register` (from the app)

```json
{ "apnsToken": "<hex, 64–200 characters, any case>", "environment": "production" | "sandbox", "platform": "ios" | "macos" }
```

→ 200 `{ "relayToken": "r1.<base64url>" }`, 400 on bad input, 429 (with `Retry-After`) after
30 a minute from one IP (an IPv6 address counts by its /64).

The relay token is `r1.` + base64url (no padding) of 12-byte IV ‖ AES-256-GCM ciphertext ‖
16-byte tag, sealed with `RELAY_SECRET`, of
`{"t":"<APNs token, lowercase hex>","e":"production|sandbox","p":"ios|macos","iat":<unix seconds>}`.
A fresh IV every time, so registering again gives another token for the same device. Servers
never see the APNs token, and the relay only takes tokens it sealed itself.

### `POST /v1/send` (from servers)

```json
{ "messages": [ { "relayToken": "r1.…", "payload": "<standard base64, at most 4000 characters>", "collapseId": "<optional, 1–64 bytes>", "ttl": 3600 } ] }
```

1 to 100 messages → 200 `{ "results": [ { "status": "…", "retryAfter": 60 } ] }`, one result per
message in the same order:

| Status | Means | The server |
| ------ | ----- | ---------- |
| `ok` | APNs took it | |
| `gone` | APNs 410, or 400 `BadDeviceToken` / `DeviceTokenNotForTopic` / `Unregistered` | forgets the device |
| `invalid` | a token the relay can't open (not one of its own, tampered, sealed with a retired secret), a payload that isn't base64 or is too long, a collapse id too long (or not printable ASCII), a `ttl` outside 0–86 400 | forgets the device or fixes the message |
| `limited` | the device's limit (30 a minute, 500 a day, counted on the APNs token, so registering again doesn't reset it) or APNs 429; `retryAfter` in seconds | tries later |
| `error` | APNs failed (auth problems, 5xx, timeouts) | counts it as a failed send |

`ttl` is in seconds, 0–86 400, default 86 400 (APNs keeps trying that long; 0: now or never).
A body that isn't this shape at all, or holds more than 100 messages, gets 400. More than
1 000 messages a minute from one IP get 429 for the whole request (with `Retry-After`).

The relay sends each message to APNs (`https://api.push.apple.com`, or
`https://api.sandbox.push.apple.com` for sandbox tokens; HTTP/2, at most 10 at a time, 10 s
timeout) as

```
POST /3/device/<APNs token>
apns-push-type: alert
apns-priority: 10
apns-topic: <APNS_TOPIC>
apns-expiration: <now + ttl, or 0 when ttl is 0>
apns-collapse-id: <collapseId, when given>
authorization: bearer <ES256 JWT, renewed every 50 minutes>

{"aps":{"alert":{"loc-key":"PUSH_FALLBACK"},"mutable-content":1,"sound":"default"},"o":"<payload>"}
```

### `GET /health`, `GET /v1`

`{ "ok": true }` and `{ "name": "ohana-relay", "version": "0.1.0" }`.

## Environment

| Variable | |
| -------- | - |
| `APNS_KEY` | required: the APNs auth key, the `.p8` file's text (a literal `\n` works for line breaks) |
| `APNS_KEY_ID` | required: the key's 10-character id |
| `APNS_TEAM_ID` | required: the team id (fa-krug: `HS26J3YA63`) |
| `APNS_TOPIC` | the app's bundle id, default `de.fa-krug.Ohana` (iOS and macOS share it) |
| `RELAY_SECRET` | required: 32 random bytes, base64 (`openssl rand -base64 32`); seals the relay tokens |
| `RELAY_SECRET_OLD` | optional, while rotating: the previous secret; its tokens are still opened, never sealed |
| `TRUST_PROXY` | `1` behind a reverse proxy: the caller's IP is the last `X-Forwarded-For` entry (the one Traefik adds). Otherwise the socket's address |
| `PORT` | default 8080 |

The relay refuses to start when a required value is missing or malformed, and says which.

## Running it

```bash
npm install
npm test            # Vitest, no network (a fake APNs, and a local HTTP/2 server for the client)
npm run typecheck
npm start           # needs the environment above; npm run dev restarts on changes
```

The image: `ghcr.io/fa-krug/ohana-relay` (`:latest`, `:main`, `:sha-<7>`), built by
`.github/workflows/relay.yml` on every push to `main` that touches `relay/`. fa-krug's runs from
[docker-compose.production.yml](docker-compose.production.yml) (Arcane project `ohana-relay`,
Traefik, redeployed by hand for now). Anywhere else:

```bash
docker run -d --name ohana-relay -p 8080:8080 \
  -e APNS_KEY="$(cat AuthKey_XXXXXXXXXX.p8)" -e APNS_KEY_ID=XXXXXXXXXX -e APNS_TEAM_ID=YYYYYYYYYY \
  -e RELAY_SECRET="$(openssl rand -base64 32)" \
  ghcr.io/fa-krug/ohana-relay:latest
```

Keep `RELAY_SECRET` once it's set: the apps' relay tokens are sealed with it.

## Apple setup

1. In the Apple Developer account, *Certificates, Identifiers & Profiles → Identifiers*: turn on
   **Push Notifications** for the App ID (`de.fa-krug.Ohana`). Nothing else there: the relay
   uses token-based auth, no certificates.
2. *Keys → +*: a key with **Apple Push Notifications service (APNs)** (environment *Sandbox &
   Production*). Download the `.p8` (only once possible) and note its **Key ID**; the **Team
   ID** is at the top right of the account page.
3. Put the `.p8`'s text, the key id and the team id with a new `RELAY_SECRET` into the relay's
   environment (fa-krug's: the Arcane project's).

One key serves sandbox (Debug builds from Xcode) and production (TestFlight, App Store); the app
says which one its token is for when it registers. A team can have only a few APNs keys: to
replace one, create the new key, switch `APNS_KEY` / `APNS_KEY_ID`, then revoke the old one.

## Rotating `RELAY_SECRET`

1. Set `RELAY_SECRET_OLD` to the current secret and `RELAY_SECRET` to a new one, redeploy. Old
   tokens still work; registrations get tokens sealed with the new one.
2. The apps register again at every start (APNs tokens change) and hand their server the new
   token. Give it a while (weeks), then remove `RELAY_SECRET_OLD`.
3. From then on, tokens of the old secret are `invalid`; the servers forget those devices,
   and their apps register again at their next start.

## Your own relay (forks)

Someone who builds the app under their own bundle id needs their own relay: APNs takes pushes
for that bundle id only with their team's key. Do the Apple setup above for their App ID, run
this image with their key, `APNS_TEAM_ID` and `APNS_TOPIC=<their bundle id>`, set the relay URL
in the app's `Info.plist` (`OhanaPushRelay`)
and `PUSH_RELAY_URL` on their server.
