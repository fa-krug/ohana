# Ohana for iPhone, iPad and Mac

A native SwiftUI client for the Ohana server in [`../web`](../web): the same families, calendar,
finances, meals, appointments and assistant, with Liquid Glass. There is no data of its own on the
device: every screen reads and writes the server's API with the device's API token (or, before a
server is connected, a read-only demo).

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
A banner above every module, the family menu and the account screen connect one. While the app
switches between the demo and a server (after pairing, after signing out or a revoked token) a
loading screen covers it until the account and families are loaded.

To connect, enter the server's address — or paste any link of the server, an invite link too
(`ServerLink` in `Core/Auth/DevicePairing.swift`: the server and the invite code are taken from
it); an https link of the server opened while signed out starts this by itself. The app opens the server's `/device/pair` page in the system browser
sheet, where you sign in as on the web (passkeys work) and confirm. The page hands the app an API
token (`ohana://auth-callback`), kept in the Keychain. It shows on the web account page as
"<device> (app)" and can be removed there; "Sign out" in the app deletes it too. For a local
server, `http://localhost:3000` works (local networking is allowed in ATS).

## Layout

```
Ohana/
  App/            OhanaApp (scenes, commands), AppModel (server, token, account, families,
                  FamilyContext: the family's API and change signals)
  Core/           APIClient + FamilyAPI (JSON over /api/v1), APIError, JSONValue, Keychain,
                  DevicePairing, DemoServer (the demo), account models, Day / Money helpers
  DesignSystem/   Content surfaces (contentCard, CardSection, chip, TintedIcon), OhanaBackground,
                  LoadState / LoadStateView, ErrorBanner, CancelButton / discardGuard, RemoteImage
  Shell/          RootView, LoadingScreen, ConnectServerView (pairing), DemoBanner, AppShell
                  (sidebar-adaptable TabView, family switcher, assistant inspector ⌘J), AccountView
  Features/       One folder per module: Overview, Calendar, Finance, Meals, Appointments,
                  Assistant, Settings
  Resources/      Assets (app icon, accent color), Localizable.xcstrings (en + de), Demo (demo data)
OhanaTests/       Swift Testing unit tests
```

## Building and testing from the command line

```bash
xcodebuild -scheme Ohana-macOS -destination 'platform=macOS' build
xcodebuild -scheme Ohana -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme Ohana-macOS -destination 'platform=macOS' test
```

In Debug builds, `-OHANA_DEV_SERVER http://localhost:3000 -OHANA_DEV_TOKEN ohana_…` (an API
token from the web account page) signs in without pairing, and `-OHANA_DEV_MODULE calendar` /
`-OHANA_DEV_ASSISTANT YES` open a module or the assistant at launch, `-OHANA_DEV_URL ohana://f/…`
opens a link (Xcode: scheme → Run →
Arguments). The test schemes run in English, since the tests compare English strings.

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
