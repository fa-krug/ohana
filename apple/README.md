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
                  widgets' source, snapshot and store, shared with the extension)
  DesignSystem/   Content surfaces (contentCard, CardSection, chip, TintedIcon), OhanaBackground,
                  LoadState / LoadStateView, ErrorBanner, CancelButton / discardGuard, RemoteImage,
                  Tints (Color.ohana, ModuleTint; shared with the widgets)
  Shell/          RootView, LoadingScreen, ConnectServerView (pairing), DemoBanner, AppShell
                  (sidebar-adaptable TabView, family switcher, assistant inspector ⌘J), AccountView
  Features/       One folder per module: Overview, Calendar, Finance, Meals, Appointments,
                  Assistant, Settings
  Resources/      Assets (app icon, accent color), Localizable.xcstrings (en + de), Demo (demo data)
OhanaWidgets/     The widget extension (OhanaWidgets / OhanaWidgets-macOS): the widgets, their
                  TimelineProvider + WidgetLoader, shared views and links, entitlements
OhanaTests/       Swift Testing unit tests
```

## Widgets

Home Screen and Lock Screen widgets on iPhone and iPad, desktop widgets on the Mac: **Today** and
**Tomorrow** (calendar entries, events, birthdays; today's events drop off once they end),
**Tonight's dinner**, **Shopping list** (what's left to buy) and **Appointment found** (the
earliest slot the enabled searches found). The Lock Screen sizes exist on iOS only.

They show the family selected in the app. The app writes which server and family that is (and
the modules the server turned off) to the App Group (`WidgetSync`); the extension loads the
family's overview (`GET /api/v1/families/{id}/overview`) from the server itself, with the device's
API token from the shared Keychain group, and keeps the last answer in the App Group for when the
server can't be reached. They refresh every 30 minutes, when an event of today ends and at
midnight, and the app asks them to reload after a change and when it goes to the background.
Signed out or in the demo they ask to open the app. A tap opens the day, recipe, shopping list or
appointment in the app (`ohana://f/{familyId}/…`).

The App Group comes from the `OhanaAppGroup` Info.plist key (build setting `OHANA_APP_GROUP`):
`group.de.fa-krug.Ohana` on iOS, `$(TeamIdentifierPrefix)de.fa-krug.Ohana` on macOS (a `group.`
id there makes macOS ask the user for access).

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
Xcode Cloud gives every build its own. The widget extension (`de.fa-krug.Ohana.Widgets`) is
embedded in both apps, so each archive includes it without a scheme of its own; its bundle id and
the App Group (`group.de.fa-krug.Ohana`, and the team-prefixed one of the Mac) must be registered
for the team: a signed build in Xcode with automatic signing does that, Xcode Cloud needs them to
exist. The app declares no encryption beyond HTTPS
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
