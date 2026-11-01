# Ohana for iPhone, iPad and Mac

The SwiftUI app for the self-hosted Ohana server in [`../server`](../server), and its only client
(the server has no web UI, only its sign-in and account pages): families, calendar, finances,
meals, appointments and assistant, with Liquid Glass. There is no data of its own on the device:
every screen reads and writes the server's API with the device's API token (or, before a server
is connected, a read-only demo).

## Requirements

Xcode 26 or newer (built here with Xcode 27) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
```

The app runs on iOS/iPadOS 26 and macOS 26 (the first releases with Liquid Glass) and later.

## Setup

```bash
cd apple
xcodegen generate
open Ohana.xcodeproj
```

Two schemes, one per platform, over one `Ohana/` source tree: **Ohana** (iOS/iPadOS) and
**Ohana-macOS** (a native Mac app, not Catalyst). `Ohana.xcodeproj` is generated and not
committed: run `xcodegen generate` again after adding or removing files.

## Demo and signing in

Without a server the app shows a demo family (`Core/Demo/`): `APIClient(demo:)` answers the API
from the JSON templates in `Ohana/Resources/Demo` (`demo-<path>.json`, dates relative to today;
handlers in `Demo+<Module>.swift` for routes that depend on the query). The demo account is a
viewer, so the screens hide editing, and any change is refused with a note to connect a server.
A banner above every module, the family picker and the account page in the settings connect one. While the app
switches between the demo and a server (after pairing, after signing out or a revoked token) a
loading screen covers it until the account and families are loaded.

To connect, enter the server's address — or paste any link of the server, an invite link too
(`ServerLink` in `Core/Auth/DevicePairing.swift`: the server and the invite code are taken from
it); an https link of the server opened while signed out starts this by itself. First the app asks
`GET /api/v1/server` (public: version, API version, enabled modules) and refuses a server older
than it needs (`ServerInfo.requiredAPIVersion`; a 404 is an older server); it asks again at every
launch and hides the modules the server turned off. Then it opens the server's `/device/pair`
page in the system browser sheet, where you sign in (passkeys work) and confirm. The page hands
the app an API token (`ohana://auth-callback`), kept in the Keychain. It shows under Settings →
Account → Signed-in devices as "<device> (app)" and can be removed there; "Sign out" in the app
deletes it too. For a local server, `http://localhost:3000` works (local networking is allowed in
ATS).

Adding a passkey, and changing the email of an account without a password, need the server's own
domain: the account page opens `{server}/account?state=…` in the same browser sheet
(`ServerAccountPage` in `Core/Auth/`), which calls back `ohana://account-callback?state=…`
(`&changed=passkey|email`) and the account reloads.

## Layout

```
Ohana/
  App/            OhanaApp (scenes, commands), AppModel (server, token, account, families,
                  FamilyContext: the family's API and change signals), WidgetSync
  Core/           APIClient + FamilyAPI (JSON over /api/v1), APIError, JSONValue, Keychain,
                  DevicePairing, ServerAccountPage, ServerInfo (version, modules), DemoServer
                  (the demo), account models, Day / Money helpers, Widgets (WidgetFeed: the
                  widgets' snapshot and store, shared with the extension), Reminders (EventKit,
                  the shopping list's sync)
  DesignSystem/   Content surfaces (contentCard, CardSection, chip, TintedIcon), OhanaBackground,
                  LoadState / LoadStateView, ErrorBanner, CancelButton / discardGuard, RemoteImage,
                  Tints (Color.ohana, ModuleTint; shared with the widgets)
  Shell/          RootView, LoadingScreen, ConnectServerView (pairing), DemoBanner, AppShell
                  (sidebar-adaptable TabView, family switcher, assistant inspector ⌘J), AccountView
  Features/       One folder per module: Overview, Calendar, Finance, Meals, Appointments,
                  Assistant, Settings
  Resources/      Assets (app icon, accent color), Localizable.xcstrings (en + de), Demo (demo data)
Shared/           Compiled into the apps and their extensions: Keychain, SharedConnection (the
                  app's server, token and family for the share extensions; the recipe import
                  request), SharedPage (what the share sheet hands over), CookTimerAttributes
                  (the cook timers' Live Activity, iOS)
ShareExtension/   "Save to Ohana" in the share sheet (targets OhanaShare for iOS and
                  OhanaShare-macOS, embedded in the apps): the server imports a web page's recipe;
                  Preprocess.js reads the page in Safari on iOS
OhanaWidgets/     Widget extension (OhanaWidgets for iOS, OhanaWidgets-macOS, embedded in the
                  apps): the Home Screen / Lock Screen / desktop widgets, and on iOS the cook
                  timers' Live Activity
OhanaTests/       Swift Testing unit tests
```

## From outside the app

- **Siri, Shortcuts, Spotlight** (`App/Intents/`): *Ask Ohana* opens the assistant; *Add to
  Shopping List*, *Add Event* and *Import Recipe* (a URL, also from the share sheet in a shortcut)
  run without opening the app and answer in a sentence. They use the server, token and family the
  app stored (`IntentConnection`); *Add to Shopping List* adds a reminder to the family's shopping
  list in Reminders (see below) and needs no server. The phrases' German is in
  `Resources/AppShortcuts.xcstrings`. *Scan Letter* (also in Spotlight, so the Home Screen search
  finds it) opens the app with the letter scanner (`ScanLetterIntent` → `FamilyContext.scanLetter()`,
  hosted by the shell like the family menu's *Scan letter*).
- **Scanning paper** (`Core/Scanning/`, `Features/Letters/`): letters (the family menu, *Scan Letter*,
  the assistant's attach menu) and receipts (Finance) come from the document camera, or a picked
  photo / PDF that Vision crops to the paper (`ScanCrop`). Their text is read on the device; the
  review can save the pages as a searchable PDF (invisible text layer, Finder / Files tags, name
  and tags suggested on the device, Apple's on-device model where available) into a folder the
  app remembers as a bookmark. A letter's review (not from the attach menu, which attaches the
  text to the chat) also lists the events, tasks and deadlines the server finds in the text
  (`POST …/ai/letter`, the family's assistant model), each ticked and editable; Done adds the
  ticked ones (events to the family's calendar, the rest to Reminders). Only the text ever goes to
  the server.
- **Share extension** (`ShareExtension/`): sharing a web page (Safari, or any app sharing a URL) to
  Ohana has the server read its recipe and save it to "Want to try"; *Undo* deletes it again, and
  cancelling while it works saves nothing (the server notices the request go away). The app's
  *Import from Web* sheet works the same. There is no App Group: the
  extension reads the token, the server's address and the selected family from the Keychain,
  where the app keeps them (`SharedConnection`; same access group in all entitlements). The app
  writes them at launch, after pairing and when the family changes, and removes them when it
  signs out.
- **Spotlight** (`Features/Meals/Recipes/RecipeSpotlight.swift`): the recipes of every family of
  the connected server's account (both lists: title, description, tags and the family's name as
  keywords; item `recipe/{familyId}/{recipeId}`, domain `recipes/{familyId}`), indexed with Core
  Spotlight once the account has loaded and again for a family a few seconds after its recipes
  change (`revision(.recipes)`). In the demo, after signing out and with Meals off the index is
  emptied. A result opens the recipe in its family (`ohana://f/{familyId}/meals/recipes/{id}`).

## Widgets

Home Screen and Lock Screen widgets on iPhone and iPad, desktop widgets on the Mac: **Today** and
**Tomorrow** (calendar entries, events, birthdays; today's events drop off once they end),
**Tonight's dinner** and **Appointment found** (the
earliest slot the enabled searches found). The Lock Screen sizes exist on iOS only.

They show the family the app shows. Like the share extension they need no App Group: the
extension reads the server, token and family from the Keychain (`SharedConnection`), loads the
family's overview (`GET /api/v1/families/{id}/overview`) itself and keeps the last answer in its
own container for when the server can't be reached (`Core/Widgets/WidgetFeed.swift`). The app
leaves the modules the server turned off in the Keychain too and reloads the widgets after loading
the account, on a family switch, after a change and when it goes to the background
(`WidgetSync`); on their own they refresh every 30 minutes, when an event of today ends and at
midnight. Signed out or in the demo they ask to open the app. A tap opens the day, recipe or
appointment in the app (`ohana://f/{familyId}/…`).

## The shopping list in Reminders

Ohana has no shopping list of its own: the server works out what the meal plan needs per shopping
day (`GET …/meals/shopping?from=`), and the app writes it into a Reminders list the user picks for
the family on this device (Settings → Shopping List, or the meal plan's toolbar), one item per
reminder ("150 g Tomato"), due on its shopping day. It only goes one way: ticking off, editing and
adding happen in Reminders, and Ohana never brings back what was deleted there nor overwrites a
title the user changed (`Core/Reminders/ShoppingReminderPlan.swift` has the rules; each reminder's
url, `ohana://f/{familyId}/meals/shopping/{date}/{key}?q=…&t=…`, marks it as Ohana's). It syncs when
it is turned on, when the app becomes active or shows another family, a few seconds after the meal
plan or recipes change, and with *Sync now* (`ShoppingReminders`). `RemindersStore` wraps EventKit
(one `EKEventStore`, full access to reminders); the Mac app has the sandbox's Calendars
entitlement, which covers reminders. Not in the demo.

## Building and testing from the command line

```bash
xcodebuild -scheme Ohana-macOS -destination 'platform=macOS' build
xcodebuild -scheme Ohana -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme Ohana-macOS -destination 'platform=macOS' test
```

In Debug builds, `-OHANA_DEV_SERVER http://localhost:3000 -OHANA_DEV_TOKEN ohana_…` (an API
token from Settings → Account → API tokens) signs in without pairing, and `-OHANA_DEV_MODULE calendar` /
`-OHANA_DEV_ASSISTANT YES` open a module or the assistant at launch, `-OHANA_DEV_URL ohana://f/…`
opens a link (Xcode: scheme → Run →
Arguments). The test schemes run in English, since the tests compare English strings.

## Releasing

Both apps ship through App Store Connect under one bundle id, `de.fa-krug.Ohana` (one app record
with an iOS and a macOS platform), to TestFlight and from there to the App Store. Once, in App
Store Connect: create that app record, and for TestFlight add the testers (internal testers are
users of the team; external ones need a beta review, which needs a demo server and account,
since the app does nothing without a server).

Xcode Cloud builds, signs and uploads the releases (the workflow is set up in Xcode / App Store
Connect). The workflow needs one Archive action per platform, each with its own scheme: iOS with
`Ohana`, macOS with `Ohana-macOS` (the `Ohana` scheme is the iOS app only, so a macOS archive of
it finds no destination). `ci_scripts/ci_post_clone.sh` generates the project with XcodeGen there, since
`Ohana.xcodeproj` isn't committed. `MARKETING_VERSION` in `project.yml` is the version people see;
raise it for a new release. The build number (`CURRENT_PROJECT_VERSION`) doesn't need editing:
Xcode Cloud gives every build its own.

Xcode Cloud's signing doesn't register bundle ids or turn capabilities on: whatever the
entitlements ask for must already be on the identifiers in the developer account (Certificates,
Identifiers & Profiles → Identifiers), or the archive builds and every export fails (`xcodebuild
-exportArchive` exit code 70; the reason is in the build's artifacts, `*-export-archive-logs/`).
Signing once from Xcode with the team's account and automatic signing sets them up too. Each
identifier is used by the iOS and the macOS target alike:

| Identifier | What it is | Capabilities to turn on |
| --- | --- | --- |
| `de.fa-krug.Ohana` | the apps | Push Notifications, Time Sensitive Notifications (finished timers come through a Focus) |
| `de.fa-krug.Ohana.Widgets` | the widget extension (on iOS also the cook timers' Live Activity) | – |
| `de.fa-krug.Ohana.Share` | the share extensions | – |
| `de.fa-krug.Ohana.NotificationService` | the notification service extensions (decrypt pushes) | – |

All of them share the app's keychain group (`keychain-access-groups`), which needs no capability.

The app declares no encryption beyond HTTPS
(`ITSAppUsesNonExemptEncryption`) and its use of `UserDefaults` in
`Ohana/Resources/PrivacyInfo.xcprivacy`; the iOS icon (`icon-1024.png`) must stay without an
alpha channel.

## Translations

German strings live per module in `Localization/<module>.de.json` (String Catalog key → German;
interpolations as `%@`, `%lld`, `%lf`; a plural is `{"one": "…", "other": "…"}`, or per language
`{"en": {…}, "de": {…}}`). `Localizable.xcstrings` is generated from them: after a merge conflict
in it, re-run the script instead of resolving it by hand. After adding strings, build once and merge:

```bash
xcodebuild -scheme Ohana -destination 'generic/platform=iOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
scripts/merge-localizations.py build/dd   # rewrites Ohana/Resources/Localizable.xcstrings, lists keys without German
```

## Conventions

- Swift 6 with main-actor default isolation; `@Observable` models, `async`/`await`, no Combine.
- A screen loads with `.task(id: family.revision(.area))` into a `LoadState` and shows it with
  `LoadStateView`; after a change it calls `family.didChange(.area)` so other screens showing the
  same data reload (the assistant does this for what its tools changed).
- Errors of actions go to the window's banner: `perform { try await … }` (VoiceOver announces it);
  every sheet's content has `.errorBanner()` so it shows there too.
- Liquid Glass only for the navigation layer and controls floating above the content (bars,
  toasts, floating buttons: `.buttonStyle(.glass)`, `.glassProminent`, `GlassEffectContainer`).
  Content sits on solid `contentCard()` / `CardSection` on `ohanaBackground()`.
- Editor sheets: `CancelButton(hasChanges:)` + `.discardGuard(hasChanges:)` (ask before
  discarding), Save in `.confirmationAction` with `.keyboardShortcut(.defaultAction)`, errors at
  the field.
- Menus: the visible module sets `focusedSceneValue(\.newItem, …)` (File ▸ New …, ⌘N) and
  `focusedSceneValue(\.moduleMenu, …)` (its own menu in the menu bar and the iPad's ⌘ list); only
  ⌘-shortcuts there, none of the system's (⌘E, ⌘F, ⌘S, ⇧⌘S, …). New Window is ⌥⌘N.
- Strings are English literals (`Text("…")`); the German translations are in
  `Resources/Localizable.xcstrings`.
- Code for both platforms: iOS-only modifiers behind `#if os(iOS)`; nothing newer than macOS 26
  without `if #available`.
