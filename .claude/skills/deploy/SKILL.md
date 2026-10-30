---
name: deploy
description: Use when asked to deploy, ship or release Ohana to production. Deploying means getting the work onto main; CI builds the image and redeploys the Arcane project.
---

# Deploy Ohana

A push to `origin/main` that touches `web/**`, `docker-compose*.yml` or the workflow runs
`.github/workflows/ci.yml` (changes to `apple/` or docs alone don't deploy): typecheck and tests → build
linux/amd64 + linux/arm64 images → push `sascha384/ohana:latest` → redeploy the Arcane
project `ohana` with `arcane-cli` (GitHub OIDC federated credential, no deploy secret) → wait
for `https://ohana.fa-krug.de/api/health`.

So deploying means: get the reviewed commits onto `main` (merge the pull request), with
`npm run typecheck` and `npm test` (in `web/`) passing on the merged result. Only the web app
deploys; the native app in `apple/` ships through Xcode / App Store Connect. Never push straight to
`main` without the user asking for it.

Coordinates: GitHub `fa-krug/ohana`, Docker Hub `sascha384/ohana`, Arcane project `ohana` at
https://arcane.fa-krug.de (compose on the Pi from `docker-compose.production.yml`), domain
`ohana.fa-krug.de`.
