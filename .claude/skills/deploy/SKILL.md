---
name: deploy
description: Use when asked to deploy, ship or release Ohana to production. Deploying means getting the work onto main (fa-krug's own server) or tagging a release (self-hosters); CI builds the image and redeploys the Arcane project.
---

# Deploy Ohana

A push to `origin/main` that touches `server/**`, `docker-compose*.yml` or the workflow runs
`.github/workflows/ci.yml` (changes to `apple/` or docs alone don't deploy): typecheck, build
of the sign-in pages' script and tests → linux/amd64 + linux/arm64 images → push
`ghcr.io/fa-krug/ohana:main` (and `:sha-…`) → redeploy the Arcane project `ohana` with
`arcane-cli` (GitHub OIDC federated credential, no deploy secret) → wait for
`https://ohana.fa-krug.de/api/health`.

So deploying means: get the reviewed commits onto `main` (merge the pull request), with
`npm run typecheck` and `npm test` (in `server/`) passing on the merged result. Never push
straight to `main` without the user asking for it.

**Releasing** for self-hosters: bump `version` in `server/package.json` on `main`, then push a
tag `v<version>` (e.g. `v0.3.0`). CI publishes `:0.3.0`, `:0.3`, `:0` and `:latest`; write the
release notes on GitHub (breaking changes first). Only when the user asks for a release.

The native app in `apple/` ships through Xcode Cloud / App Store Connect (apple/README.md).

Coordinates: GitHub `fa-krug/ohana`, image `ghcr.io/fa-krug/ohana` (GITHUB_TOKEN pushes it; the
package must be public so self-hosters and the Pi can pull it), Arcane project `ohana` at
https://arcane.fa-krug.de (compose from `docker-compose.production.yml`), domain
`ohana.fa-krug.de`.
