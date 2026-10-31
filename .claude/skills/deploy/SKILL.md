---
name: deploy
description: Use when asked to deploy, ship or release Ohana to production. Deploying means getting the work onto main: CI publishes the image (self-hosters' :latest too) and redeploys the Arcane project.
---

# Deploy Ohana

A push to `origin/main` that touches `server/**`, `docker-compose*.yml` or the workflow runs
`.github/workflows/ci.yml` (changes to `apple/` or docs alone don't deploy): typecheck, build
of the sign-in pages' script and tests → linux/amd64 + linux/arm64 images → push
`ghcr.io/fa-krug/ohana:latest`, `:main` and `:sha-…` → redeploy the Arcane project `ohana` with
`arcane-cli` (GitHub OIDC federated credential, no deploy secret) → wait for
`https://ohana-app.fa-krug.de/api/health`.

So deploying means: get the reviewed commits onto `main` (merge the pull request), with
`npm run typecheck` and `npm test` (in `server/`) passing on the merged result. Never push
straight to `main` without the user asking for it.

There are no release tags: every push to `main` is a release for self-hosters too (`:latest`).
So `main` must always be something you'd run at home.

The native app in `apple/` ships through Xcode Cloud / App Store Connect (apple/README.md).

Coordinates: GitHub `fa-krug/ohana`, image `ghcr.io/fa-krug/ohana` (GITHUB_TOKEN pushes it; the
package must be public so self-hosters and the Pi can pull it), Arcane project `ohana` at
https://arcane.fa-krug.de (compose from `docker-compose.production.yml`), domain
`ohana-app.fa-krug.de`.

The website https://ohana.fa-krug.de (the docs, Imprint, privacy policy) is separate: VitePress in
`docs/`, published to GitHub Pages by `.github/workflows/pages.yml` on every push to `main` that
changes `docs/` (the build fails while `docs/.vitepress/operator.ts` lacks the Imprint's contact
details).
