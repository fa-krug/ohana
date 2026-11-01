# The app

Ohana's only client is a native app for **iPhone, iPad (iOS/iPadOS 26)** and **Mac (macOS
26)**, written in SwiftUI. It has no data of its own: every screen reads and writes your
server's API. Its source is in [`apple/`](../apple) under the Mozilla Public License 2.0.

## The demo

Before you connect a server the app shows a **demo family** with made-up data, so you can look
around. The demo is read-only and never talks to the network; a banner above every page
connects your own server.

## Connecting your server

1. Tap **Connect your Ohana server** and enter the address, e.g. `ohana.example.com`. Pasting
   any link of the server works too, an **invite link** included: the app takes the server and
   the invite from it.
2. The app checks the server (`/api/v1/server`) and refuses one that is too old for it.
3. Your server's sign-in page opens in a browser sheet. Sign in (passkeys work there, or create
   your account from an invite) and confirm **Connect**.
4. The app receives its own **API token** and keeps it in the Keychain. It shows under
   *Settings → Account → Signed-in devices* as "&lt;device&gt; (app)"; removing it there, or
   *Sign out* in the app, ends it.

For a server on your own network without HTTPS, use its address with `http://` (e.g.
`http://192.168.1.20:8000`) and sign in with a password.

## Families, roles and modules

- If you're in several families, switch between them at the top of the sidebar.
- **Viewers** see everything but can't change anything; the app hides the editing controls.
- Modules the server turned off disappear from the app.

## Search

The search tab (🔍, at the end of the iPhone's tab bar and at the top of the sidebar; ⌘K on the
Mac and iPad keyboards) looks through every module at once: recipes, calendar events and notes,
transactions, appointment searches, the people of the family and your own assistant chats. Every
word you type has to appear (upper case and accents don't matter, so `muller` finds *Müller*); a
result opens where it lives, a transaction in its editor.

## The assistant

The ✨ button at the top right of every page opens the assistant next to what you're looking at
(⌘J on the Mac and iPad keyboards, ⇧⌘J for a new question). On the Mac it's also in the menu bar,
and *Ask Ohana* is available as a Shortcut and to Siri.

## Notifications and links

Ohana's notifications reach you through the channels your family set up (Pushover, Pushbullet,
Telegram, email, ntfy). Their links (`https://<your server>/f/…`) open a page with an **Open the
app** button that opens the same place in the app.

## Passkeys and your account

Adding a passkey, and changing the email of an account without a password, happen on your
server's own site (passkeys are bound to its domain): the app opens the page in the same browser
sheet and comes back when you're done. Personal **API tokens** for your own scripts are under
*Settings → Account*.

## Building it yourself

You need Xcode 26 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd apple
xcodegen generate
open Ohana.xcodeproj
```

The schemes **Ohana** (iOS/iPadOS) and **Ohana-macOS** build the two apps from one source
tree. Signing, tests and releasing: [apple/README.md](../apple/README.md).
