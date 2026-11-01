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

## Offline

The app keeps a copy of what your server last sent: your families and every screen you opened
(the overview, the calendar, the meal plan, recipes, finances, appointments,
past chats). Shortly after it starts it also loads the selected family's main screens and the
recipes of the current meal plan in the background (on Wi-Fi or mobile data, not in Low Data
Mode), so they're there before you open them. It opens on that copy at once and asks the
server behind; a small *Updating…* shows meanwhile. Without a connection the copy stays
readable, marked *Offline · as of 9:41*, and is replaced as soon as the server answers again.

Some changes work offline too and are sent when you're back online, even after quitting the
app: **calendar days and notes**. If the server refuses one (say, a type was deleted
meanwhile), the server wins: the change is dropped, a message says so, and the screen
shows the server's state. Other changes need the server. Signing out removes the copy and the
changes not sent yet.

## Families, roles and modules

- If you're in several families, switch between them at the top of the sidebar.
- **Viewers** see everything but can't change anything; the app hides the editing controls.
- Modules the server turned off disappear from the app.

## Shopping in Reminders

Ohana doesn't keep a shopping list of its own. The meal plan works out what each shopping day
needs, and the app writes those items into a **Reminders** list you pick in the meal plan (per
family, on each device), each one due on its shopping day. Tick, edit and add items in
Reminders, or share the list with the family over iCloud. When the meal plan changes, the app
updates the items it wrote; what you changed or deleted yourself stays as it is. Viewers can use
it too.

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

If you let the app use Reminders, the assistant can read your open reminders (any list) and
suggest changes to them, such as adding groceries to your shopping list. It never changes them by
itself: the chat shows what it wants to do, with **Apply** and **Don't apply**.

## Widgets

Add Ohana's widgets to the Home Screen, the Lock Screen (iPhone and iPad) or the Mac's desktop:
**Today** and **Tomorrow** (calendar, events, birthdays), **Tonight's dinner** and
**Appointment found** (the earliest slot your searches found). They show the family
selected in the app, load it from your server with the app's token and refresh on their own; a
tap opens the same thing in the app. Before you connect a server they ask you to open the app.

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
