# Development

The repository holds two projects: **[`server/`](../server)** (TypeScript on Node.js 22: Hono,
Drizzle over SQLite, Vitest) and **[`apple/`](../apple)** (the SwiftUI app). This website is
[`docs/`](https://github.com/fa-krug/ohana/tree/main/docs) (VitePress).

## The server

```bash
cd server
npm install
npm run db:migrate   # creates ./data/ohana.db with the shared units and ingredients
npm run dev          # http://localhost:3000 (API + sign-in pages, restarts on changes)
npm run worker       # the background worker, in a second terminal
npm test             # Vitest
npm run typecheck
```

Point the app at `http://<your machine>:3000` to try it against your checkout. Settings come
from the environment ([server/.env.example](../server/.env.example)). Locked out?
`npm run setup-link -- <email>` prints a new setup link.

- **Schema changes:** edit `server/lib/db/schema*.ts`, then `npm run db:generate` for the
  migration.
- **AI without a provider:** `npm run mock-ai` serves a scripted stand-in on
  `http://localhost:4011/v1` (model `mock-large`); run server and worker with
  `AI_ALLOW_PRIVATE_ENDPOINT=1` to use it.
- **Tests** use an in-memory database and never touch the network.
- **The API** is described in [openapi.yaml](https://github.com/fa-krug/ohana/blob/main/docs/openapi.yaml):
  keep it in step with route changes.

[CLAUDE.md](../CLAUDE.md) is a detailed map of the architecture and conventions, worth reading
whoever (or whatever) writes the code.

## The app

```bash
brew install xcodegen
cd apple
xcodegen generate
open Ohana.xcodeproj
```

Tests run in Xcode or with `xcodebuild test`; German strings are checked with
`python3 apple/scripts/merge-localizations.py --check`. See
[apple/README.md](../apple/README.md).

## This website

```bash
cd docs
npm install
npm run dev     # http://localhost:5173
npm run build   # → docs/.vitepress/dist
```

The pages are the Markdown files in `docs/`. Links to files outside `docs/` (like
`../server/.env.example`) work on GitHub and become links to the repository on the site. A push
to `main` that changes `docs/` publishes the site to GitHub Pages.

## Releases

Every push to `main` that passes the tests is a release: CI publishes
`ghcr.io/fa-krug/ohana:latest` (and `:main`, `:sha-<commit>`) for amd64 and arm64. So `main`
must always be something you'd run at home. The app is released through the App Store / TestFlight
(see [apple/README.md](../apple/README.md)).

## Contributing

For anything bigger than a fix, open an issue first. Keep pull requests focused, with tests,
and keep these in mind:

- **The API only grows**: the app in people's hands may be older than their server.
- **Two languages**: user-facing strings need English and German.
- **Secrets never leave the server**: stored keys are encrypted and only reported as `hasToken`.

The details: [CONTRIBUTING.md](../CONTRIBUTING.md). By contributing you agree that your
contribution is licensed under the license of the part it changes (AGPL-3.0 outside `apple/`,
MPL-2.0 in `apple/`).
