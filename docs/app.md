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

## Covering days

A type with the role *Needs cover* (e.g. "Day care closed") marks weekdays someone has to look
after the children; a *Covers* type (e.g. "Vacation Dad", "Grandma") covers them. A covering type
can be set to *Only when covering* (Settings → Calendar → the type): its days then show only where
they cover a day that needs cover. You can enter a whole stretch when someone is available, and the
calendar shows them only on the days they're needed. The other days stay saved and counted, they're
just hidden (also from Apple Calendar and the overview); select such a day to see the type ticked
and take it off.

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

## Holidays

In Settings → Calendar an editor can import the public and / or school holidays of the family's
region as day entries ("Holiday", "School holidays"), this year's and next year's, kept up to
date by the server. The region comes from the home address, or pick one. Days you delete stay
deleted; turning a kind off removes its days from today on.

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
notification opens its day. *Settings → Chores* sets when the morning, the day and the evening
start (07:00, 12:00 and 18:00 at first): a chore's time puts it in its part, and a chore without
a time is due when its part starts.

## Syncing an account with its bank

Instead of importing CSV files, a finance account can fetch its transactions from the bank
itself. For now the bank is **comdirect** (its free REST API for private customers); others can
be added later. Editors link an account in its settings; everyone in the family sees when it
last synced.

**1. Turn on comdirect's API access.** Log in to the [comdirect online
banking](https://www.comdirect.de), open **Verwaltung → Entwicklerzugang** and activate the
access to the REST API. You get a **client ID** (it starts with `User_`) and a **client
secret**: treat the secret like a password. Use **photoTAN push** as your TAN method if you can
(approving the login in the comdirect app is all a sync then asks of you); a photoTAN graphic or
an SMS TAN work too.

**2. Link the account.** In the account's settings, choose *comdirect* and enter the client ID,
the client secret, your **Zugangsnummer** and your **PIN**. If you have more than one account at
comdirect, add the **IBAN** of the one this account stands for; without one, Ohana takes your
only Girokonto. The server keeps these details encrypted and never sends them back to the app:
to change them, enter the new ones, empty fields keep what's stored.

A comdirect **Visa credit card** can be an account of its own: link it the same way, with the
same login, and type its **card number** in the field *IBAN or card number*. The last four digits
are enough, and a masked number as on your statement (`4871 78XX XXXX 0175`) works too; Ohana
keeps only those four digits. Its transactions are dated by the day of the purchase, with the shop
as payee. If the Girokonto is linked as well, the monthly card bill (*Visa-Kartenabrechnung*)
pairs up as a transfer between the two. A **debit card** (Visa-Debitkarte) needs nothing of its
own: its payments are on the Girokonto already.

**3. Sync.** Tap *Sync* on the account. Your server logs in at comdirect, which asks for a TAN:
approve the login in the comdirect app, or scan the photoTAN graphic the app shows and type the
TAN (an SMS TAN the same way). The server then fetches the **booked** transactions and adds the
new ones, with payee and purpose; transfers to and from the family's other accounts are linked
on the way, as after a CSV import. Pending transactions come once they're booked.

- The first sync of an empty account goes two years back. An account that already has
  transactions (from CSV files, say) only gets the ones after its latest, so nothing comes
  twice. Later syncs look two weeks back from the last booking they brought, for late bookings;
  what is there already is recognized.
- **Import All Transactions** (in the account's settings, for an account that is linked) brings
  in the bank's whole history once, e.g. after you imported CSV files first. A transaction
  already in Ohana with the same day and amount as one of the bank's is kept as it is (text,
  category, note) and from then on counts as the bank's, so it never comes twice; only the
  others are added. At the end Ohana says how many it kept, added, and how many of the
  account's transactions the bank doesn't list: those stay untouched, but they may be
  duplicates from a CSV file worth a look. comdirect gives a credit card's newest 500 bookings
  only.
- Every transaction shows where it came from: a bank icon for the bank's, a document icon for a
  CSV file's, none for one entered in Ohana. The list's *Origin* filter shows one kind; *Not
  from the bank* after a full import are the ones the bank doesn't list. You can also ask the
  assistant, e.g. "list the giro account's transactions that aren't from the bank" and then
  "delete them" (it asks before deleting; the change can be undone).
- A sync within about 20 minutes of the last one usually needs no new TAN.
- comdirect **locks the online banking** after five TAN requests without a confirmed TAN in
  between, or three wrong TANs. So Ohana never asks twice by itself: a wrong TAN ends the sync,
  and after three requests in a row that weren't confirmed it won't start another one until you
  have logged in once on comdirect's website with a TAN (or saved the bank connection again).
  A refused PIN, too, stops the syncs until the connection is saved again.
- A linked account takes no CSV files. Unlinking keeps its transactions.

## Search

The search tab (🔍, at the end of the iPhone's tab bar and at the top of the sidebar; ⌘K on the
Mac and iPad keyboards) looks through every module at once: recipes, calendar events and notes,
transactions, appointment searches, the people of the family and your own assistant chats. Every
word you type has to appear (upper case and accents don't matter, so `muller` finds *Müller*); a
result opens where it lives, a transaction in its editor.

## The assistant

The round ✨ button at the bottom right of every page opens the assistant over what you're looking
at (⌘J on the Mac and iPad keyboards, ⇧⌘J for a new question); tap it again to close it. On the Mac it's also in the menu bar,
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

## Knowledge base

Where the server has it on, editors get a **Knowledge** page (on iPhone in the family menu): the
family's paperwork, read from one folder, usually an iCloud Drive folder the parents share. Choose
it once on each device in Settings → Knowledge; the app reads the files' text on the device and
sends only the text to your server, never the files. Scans without text are read on the device
too: a page lying on its side is turned first, and tables (a timetable, say) keep their rows and
columns. With the assistant set up, *Read difficult scans with the assistant* in Settings →
Knowledge sends the pages the device couldn't read well to the family's AI as images, which writes
out their text (handwriting too). Turned on, it checks every scan in the folder once, the ones read
before too.

The page lists the documents newest first with their date, whose they are, their tags and a short
summary (when the assistant is set up). Search them, or narrow the list by folder, person or tag. A
document shows its summary and the facts in it, each with the passage it comes from, and its text
page by page. **Open Original** opens the file itself from the folder on your device: a PDF at the
page of the fact you tapped, with its passage marked. A device without the folder offers to choose
it. *Read Again* reads the file on this device once more, *Read Again with the Assistant* also has
the family's AI read every page (pages it wrote out are marked), *Leave Out* keeps it out of the
knowledge base (*Show Left Out* lists those), and on the Mac *Show in Finder* finds the file.
Each summary also comes with keywords (what the document is and other words for it) that the
search uses, so a timetable is found as "Stundenplan" or "Schulschluss" even when its text is only
the table. *Rewrite Summaries* in Settings → Knowledge has the assistant write again the summaries
from before keywords existed and the failed ones, or all of them: one request to your AI provider
each, and every summary stays until its new one is written.

The assistant answers from the knowledge base too, and names its sources: a small number after a
statement, and a list of the documents below the answer. Tap one to read the passage, open the
original at its page or show the document; the search tab finds documents as well.

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
