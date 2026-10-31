# Contributing to Ohana

Thanks for helping! Ohana is a family app run by families on their own servers, so changes
should keep it simple to run, private by default and reliable.

## Before you start

- For anything bigger than a fix, open an issue first and describe what you want to change and
  why, so we can agree on the approach before you spend time on it.
- Keep pull requests focused: one change per pull request, with tests.

## The code

- [`server/`](server): TypeScript, Hono, Drizzle over SQLite, Vitest. Route logic lives in
  `server/lib/<module>/`, the HTTP wiring in `server/http/`. Long-running work belongs in the
  worker (`server/worker/`), never in a request.
- [`apple/`](apple): SwiftUI for iOS/iPadOS and macOS (see [apple/README.md](apple/README.md)).
- [`CLAUDE.md`](CLAUDE.md) is a detailed map of the architecture and conventions; it is
  worth reading whoever (or whatever) writes the code.

## Checks

In `server/`:

```bash
npm run typecheck
npm test
```

Tests use an in-memory database and never touch the network. For the app, run the unit tests
in Xcode (or `xcodebuild test`, see apple/README.md) and
`python3 apple/scripts/merge-localizations.py --check`.

## Guidelines

- **The API only grows.** The app in the App Store may be older than the server it talks to.
  Add fields and routes; don't remove or rename them. A change an older app can't handle needs
  a new `API_VERSION` (`server/lib/server-info.ts`) and the app's `requiredAPIVersion`.
- **Two languages:** user-facing strings need English and German (server:
  `server/lib/i18n/locales/{en,de}.json`; app: `apple/Localization/*.de.json`).
- **Secrets never leave the server:** stored keys and tokens are encrypted and only reported
  as `hasToken`.
- **Schema changes** come with a Drizzle migration (`npm run db:generate`).

## License of contributions

By contributing you agree that your contribution is licensed under the license of the part of
the repository it changes: AGPL-3.0 for everything outside `apple/`, MPL-2.0 for `apple/`.
