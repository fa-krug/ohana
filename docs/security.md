# Security

Ohana holds a family's calendar, finances, health appointments and AI keys, so security
reports are very welcome.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub's
[private vulnerability reporting](https://github.com/fa-krug/ohana/security/advisories/new) with
what you found, how to reproduce it and what an attacker could do. A fix is published as a new
image as soon as it lands on `main`.

Only the newest image (`ghcr.io/fa-krug/ohana:latest`) gets security fixes: keep your server
[updated](/self-hosting#updating).

## How Ohana protects your data

- **Sign-in** with passkeys (WebAuthn) or passwords hashed with argon2id; failed password
  attempts are rate limited.
- **Tokens** (sessions, API tokens, setup links) are stored only as SHA-256 hashes.
- **Secrets at rest** (AI and search keys, notification tokens, SMTP passwords) are encrypted
  with AES-256-GCM and never sent back to the app.
- **Families are separate:** every request is checked against the family's membership, and a
  family you're not in answers `404`. Server administrators manage accounts, not families' data.
- **Outbound requests** from the assistant refuse private network addresses (unless you allow
  your own AI endpoint), and requests to outside services time out.

## Running a server safely

- Serve Ohana over **HTTPS** only and keep `AUTH_SECRET` (and `ENCRYPTION_KEY`) secret.
- Leave `AI_ALLOW_PRIVATE_ENDPOINT` off unless your AI model runs on your own network.
- **Copy the backups off the machine**: they contain everything.
- Update regularly: `docker compose pull && docker compose up -d`.
