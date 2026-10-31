---
title: Licenses
description: Ohana's licenses, third-party software and trademarks
---

# Licenses

Ohana is free and open-source software.

## The server: GNU AGPL-3.0

The server ([`server/`](../../server)) and everything in the repository outside `apple/`,
including this documentation, is licensed under the
**[GNU Affero General Public License v3.0](https://github.com/fa-krug/ohana/blob/main/LICENSE)**.
You may use, study, change and share it. If you run a modified version for other people over a
network, you must offer them the source code of your version.

## The app: Mozilla Public License 2.0

The app for iPhone, iPad and Mac ([`apple/`](../../apple)) is licensed under the
**[Mozilla Public License 2.0](https://github.com/fa-krug/ohana/blob/main/apple/LICENSE)**, which
works with distribution through the App Store. Changes to its files are shared under the same
license.

## Contributions

By contributing you agree that your contribution is licensed under the license of the part of
the repository it changes: AGPL-3.0 outside `apple/`, MPL-2.0 in `apple/`.

## No warranty

As stated in both licenses, Ohana is provided "as is", without warranty of any kind, to the
extent permitted by applicable law. Whoever runs an Ohana server is responsible for it, its
backups and the data on it.

## Third-party software

Ohana is built on open-source software under its own licenses, among them
[Node.js](https://nodejs.org), [Hono](https://hono.dev), [Drizzle ORM](https://orm.drizzle.team),
[better-sqlite3](https://github.com/WiseLibs/better-sqlite3),
[SimpleWebAuthn](https://simplewebauthn.dev), [sharp](https://sharp.pixelplumbing.com) and
[zod](https://zod.dev) on the server. The complete list is in
[server/package.json](https://github.com/fa-krug/ohana/blob/main/server/package.json) and its
lock file. This website is built with [VitePress](https://vitepress.dev) (MIT) and shows the API
reference with [Redoc](https://github.com/Redocly/redoc) (MIT).

## Trademarks

Apple, iPhone, iPad, Mac, macOS, Siri and App Store are trademarks of Apple Inc. Doctolib,
jameda and the other services named on this website are trademarks of their respective owners.
Ohana is an independent project and not affiliated with, endorsed or sponsored by any of them.
