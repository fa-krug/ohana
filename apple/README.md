# Ohana for iPhone, iPad and Mac

A native SwiftUI client for the Ohana server in [`../web`](../web): the same families, calendar,
finances, meals, appointments and assistant, with Liquid Glass. There is no data of its own on the
device: every screen reads and writes the server's API with the device's API token.

## Requirements

Xcode 27 (iOS 27 / macOS 27 SDKs) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
```

The iPhone/iPad app needs iOS 27; the Mac app runs from macOS 26 (Tahoe, the first release with
Liquid Glass).

## Setup

```bash
cd apple
xcodegen generate
open Ohana.xcodeproj
```

Two schemes, one per platform, over one `Ohana/` source tree: **Ohana** (iOS/iPadOS) and
**Ohana-macOS** (a native Mac app, not Catalyst). `Ohana.xcodeproj` is generated and not
committed: run `xcodegen generate` again after adding or removing files.

## Signing in

Enter the server's address; the app opens the server's `/device/pair` page in the system browser
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
                  DevicePairing, account models, Day / Money helpers
  DesignSystem/   Liquid Glass helpers (glassCard, GlassSection, TintedIcon), OhanaBackground,
                  LoadState / LoadStateView, ErrorBanner, RemoteImage
  Shell/          RootView, WelcomeView (pairing), AppShell (sidebar-adaptable TabView, family
                  switcher, assistant inspector ⌘J), AccountView
  Features/       One folder per module: Overview, Calendar, Finance, Meals, Appointments,
                  Assistant, Settings
  Resources/      Assets (app icon, accent color), Localizable.xcstrings (en + de)
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
`-OHANA_DEV_ASSISTANT YES` open a module or the assistant at launch (Xcode: scheme → Run →
Arguments). The test schemes run in English, since the tests compare English strings.

## Translations

German strings live per module in `Localization/<module>.de.json` (String Catalog key → German;
interpolations as `%@`, `%lld`, `%lf`). After adding strings, build once and merge:

```bash
xcodebuild -scheme Ohana -destination 'generic/platform=iOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
scripts/merge-localizations.py build/dd   # rewrites Ohana/Resources/Localizable.xcstrings, lists keys without German
```

## Conventions

- Swift 6 with main-actor default isolation; `@Observable` models, `async`/`await`, no Combine.
- A screen loads with `.task(id: family.revision(.area))` into a `LoadState` and shows it with
  `LoadStateView`; after a change it calls `family.didChange(.area)` so other screens showing the
  same data reload (the assistant does this for what its tools changed).
- Errors of actions go to the window's banner: `perform { try await … }`.
- Liquid Glass for the navigation layer and floating controls (`.buttonStyle(.glass)`,
  `.glassProminent`, `GlassEffectContainer`), `glassCard()` for cards on `ohanaBackground()`.
- Strings are English literals (`Text("…")`); the German translations are in
  `Resources/Localizable.xcstrings`.
- Code for both platforms: iOS-only modifiers behind `#if os(iOS)`; nothing newer than macOS 26
  without `if #available`.
