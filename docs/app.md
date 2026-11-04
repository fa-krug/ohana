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
server behind, quietly. Without a connection the copy stays readable and is replaced as soon
as the server answers again; only an error the server answers shows, as a message at the top.

Some changes work offline too and are sent when you're back online, even after quitting the
app: **calendar days and notes**, and **chores** (new, changed, deleted or ticked off). If the
server refuses one (say, a type was deleted meanwhile), the server wins: the change is dropped,
a message says so, and the screen shows the server's state. Other changes need the server. Signing out removes the copy and the
changes not sent yet.

## Apple Calendar

Settings → Calendar → *Sync with Apple Calendar* links the family's calendar with a calendar of
Apple Calendar on this device: an iCloud, Google or Exchange one, or a new one named after the
family. Events go both ways, edits and deletions too (when both sides changed an event, Ohana's
wins): events over several days keep their days, a repeating event stays one repeating event
with its rule, and an occurrence changed or deleted on its own on one side is changed or deleted
on the other. The day entries (vacation, holidays, …) go to Apple Calendar only, as all-day
events over each run of days, and changes made to them there are put back. It covers a month
back and a year ahead, and runs while the app is open: at launch, when it comes to the front,
every 15 minutes, and when either side changes. Viewers only get the family's events, nothing
goes back. Several devices can sync into the same iCloud calendar without copying events twice.

## Families, roles and modules

- If you're in several families, switch between them in the menu at the top of the sidebar (iPad
  and Mac). On iPhone the family page sits behind the tabs, as in Mail: tap the family button at
  the top left or swipe in from the left edge. It lists your families and opens appointments,
  chores, *Scan letter* and the settings.
- **Viewers** see everything but can't change anything; the app hides the editing controls.
- Modules the server turned off disappear from the app.
- On iPad and Mac you can drag a recipe onto a day of the meal plan, a meal onto another day, or a
  calendar event onto another day.
- Not sure what a button does? Long-press it for a tip (on the Mac, hover over it).

## Members, colors and photos

Settings → Household lists the family. Tap someone to open their page: pick their **color**
(entry types and chores show in it) and their birthday. Tap the big picture to add a **photo**,
then pinch and drag to choose what shows in the circle; tap it again later to change the crop,
or use its menu to choose another picture or remove it. You change your own; editors change
anyone's, including the people without an account.

## Shopping in Reminders

Ohana doesn't keep a shopping list of its own. The meal plan works out what each shopping day
needs, and the app writes those items into a **Reminders** list you pick in the meal plan (per
family, on each device), each one due on its shopping day. Tick, edit and add items in
Reminders, or share the list with the family over iCloud. When the meal plan changes, the app
updates the items it wrote; what you changed or deleted yourself stays as it is. Viewers can use
it too.

## Chores

Chores shows one day at a time, in **Morning**, **Day** and **Evening**, with what's overdue on
top of today; move between days with the arrows or the date, or see *All Chores*. Tap the circle
to tick a chore off (a repeating one for that day) and the bell to choose whether it notifies
you. New chores ask for whom, when (a part of the day, or a time), how they repeat and who gets
the notification. Changes show at once and are sent in the background, offline too. A chore's
notification opens its day.

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
suggest changes to them, such as adding groceries to your shopping list. With access to your
calendars it sees your Apple Calendar events and can suggest new ones or changes. It never changes
either by itself: the chat shows what it wants to do, with **Apply** and **Don't apply**.

The paperclip attaches a scanned letter: the assistant lists its events, tasks and deadlines, and
you tick which to add.

## Letters and scanning

*Scan letter* (in the family menu, as a Shortcut, or by sharing a photo or PDF with Ohana) scans a
letter with the camera; on the Mac you pick photos or a PDF. The text is read on the device. The
review suggests a name ("date_Person_Title"), the date and tags (only ones you already use, such as
the name of whose letter it is), and saves the letter as a **searchable PDF** into the folder you
chose last. With the assistant on, editors also see the **events, tasks and deadlines** found in
it, ticked and editable: *Done* adds the events to the family's calendar and the tasks and
deadlines to Reminders. Receipts scanned in Finance can be kept as PDFs the same way. Once the
family's knowledge folder is chosen on the device (Settings → Knowledge), scans are saved into
that folder instead, with no folder to pick, and their text goes into the knowledge base.

## Recipes from the web

In the recipe list, *Import from Web* takes a page's address and saves the recipe on *Want to
try*. In Safari, share the page to **Save to Ohana**: it tells you whether the page is a recipe,
then hands it to your server and closes. The recipe shows as a placeholder until it's ready, and
you get a notification; a failed import stays there to try again.

## Siri, Shortcuts and Spotlight

Shortcuts and Siri can **ask Ohana**, **add to the shopping list** (a reminder in the family's
list), **add an event**, **import a recipe** and **scan a letter**, most without opening the app.
Your recipes are in Spotlight. The cook view turns durations in a step into **timers**, with a
notification when they're done and, on iPhone, a Live Activity on the Lock Screen.

## Widgets

Add Ohana's widgets to the Home Screen, the Lock Screen (iPhone and iPad) or the Mac's desktop:
**Today** and **Tomorrow** (calendar, events, birthdays), **Tonight's dinner** and
**Appointment found** (the earliest slot your searches found). They show the family
selected in the app, load it from your server with the app's token and refresh on their own; a
tap opens the same thing in the app. Before you connect a server they ask you to open the app.

## Notifications and links

Turn on *Settings → Notifications on this device* to get Ohana's notifications in the app, and
mute the families you don't want to hear from on this device. They go through fa-krug's push relay,
encrypted so that only your device can read them; what is sent is chosen per family under
*Household → Notifications* (and per appointment search, and per chore by its bell). A tap opens
the place it's about. Your server's operator can turn the relay off
([configuration](/configuration)).

The channels your family set up (Pushover, Pushbullet, Telegram, email, ntfy) get notifications
too. Their links (`https://<your server>/f/…`) open a page with an **Open the app** button that
opens the same place in the app.

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
