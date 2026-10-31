# Security

Ohana holds a family's calendar, finances, health appointments and AI keys, so security
reports are very welcome.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub's
[private vulnerability reporting](https://github.com/fa-krug/ohana/security/advisories/new)
with what you found, how to reproduce it and what an attacker could do. You'll get an answer
as soon as possible; fixes are released as a new image and noted in the release notes.

## Supported versions

Only the newest release (`ghcr.io/fa-krug/ohana:latest`) gets security fixes. Keep your server
updated (see [docs/self-hosting.md](docs/self-hosting.md#updating)).

## For people running a server

- Serve Ohana over HTTPS only and keep `AUTH_SECRET` (and `ENCRYPTION_KEY`) secret.
- Leave `AI_ALLOW_PRIVATE_ENDPOINT` off unless your AI model runs on your own network.
- Copy the backups off the machine; they contain everything.
