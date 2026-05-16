# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Cozy Fox is a glanceable Chicago transit dashboard for iPhone (CTA train/bus, Metra, Divvy, Northwestern Intercampus). Swift 6 / iOS 26+, **no backend** — the phone talks directly to provider APIs.

## Build and run

The Xcode project is generated, not committed (`CozyFox.xcodeproj/` is gitignored). Regenerate any time `project.yml` or the SwiftPM package layout changes:

```bash
xcodegen generate         # installs via `brew install xcodegen`
open CozyFox.xcodeproj
```

Live Activities, region monitoring, and motion don't work in the Simulator — use a real device with iOS 26+ for end-to-end testing.

## Tests

Two test suites with **different frameworks** — don't mix them up:

- `Packages/TransitCore/Tests/*` uses **Swift Testing** (`import Testing`, `@Suite`, `@Test`). Run from the CLI without Xcode:
  ```bash
  swift test --package-path Packages/TransitCore
  # single suite / test:
  swift test --package-path Packages/TransitCore --filter DepartureUrgencyTests
  swift test --package-path Packages/TransitCore --filter "DepartureUrgency/approachingAtBoundary"
  ```
- `CozyFoxTests/*` also uses Swift Testing but lives in the app target (it `@testable import CozyFox`). It runs through Xcode's `CozyFox` scheme (`xcodebuild test -scheme CozyFox -destination 'platform=iOS Simulator,name=iPhone 16'`). Anything that depends on `TransitCore` should live in the SPM tests unless it actually needs the app target.

API decoder tests use fixture JSONs (`Tests/TransitAPITests/Fixtures/`, copied verbatim into the test bundle).

## Architecture

Three binaries (app, widget, live activity) all sit on top of one SwiftPM package, `Packages/TransitCore/`. The package is split into seven libraries with a strict dependency direction — **`TransitModels` ← `TransitAPI`, `TransitCache`, `TransitLocation` ← `TransitDomain` ← `TransitUI`** (plus `ChicagoTheme` consumed by UI layers). Keep this direction; the orchestrator-style code (`RefreshCoordinator`, learning stores) lives in the app target, not in the package, because it depends on app-only services like `BGTaskScheduler` and `ActivityKit`.

- **`TransitModels`** — pure data types and bundled JSON catalogs (`CTAStations.json`, `CTABusStops.json`, `MetraCatalog.json`, `IntercampusCatalog.json`). `Catalogs.prewarm()` schedules the larger catalogs onto a background queue so the first refresh doesn't stall on a 7 MB Metra decode.
- **`TransitAPI`** — `HTTPClient` plus one client per upstream: `CTATrainClient`, `CTABusClient`, `CTAAlertsClient`, `MetraClient`, `DivvyGBFSClient`, `NorthwesternIntercampusClient`. Pure request/response; no caching, no orchestration.
- **`TransitCache`** — `TransitStore` (SwiftData, app-group-scoped via `AppGroup.identifier = "group.net.thoughtbison.cozyfox"`) and `PreferencesStore` (UserDefaults on the same suite). The app falls back to an in-memory container if SwiftData fails to open (see `CozyFoxApp.init`).
- **`TransitLocation`** — `LocationCoordinator` over CoreLocation. Region monitoring around Home/Work + one-shot foreground updates only; no continuous tracking.
- **`TransitDomain`** — planners, resolvers, predictors, and the learning algorithms (`ArrivalBiasReader`, `LocalPredictionEngine`, `CommutePlanner`, `PortfolioEvaluator`, `BoardingDetector`, etc.). Most of these are pure functions over a `Clock` (use `FakeClock` in tests).
- **`ChicagoTheme`** — design system: `ChicagoPalette`, `ChicagoTypography` (Big Shoulders + Roboto), `ChicagoStar`, `BigNumber`, `RouteBadge`, `ChicagoCard`. **Call `ChicagoTheme.bootstrap()` once from every binary's entry point** to register the bundled TTFs — the app, widget, and live activity each do this. Fonts must stay `.copy("Resources/Fonts")` in `Package.swift`; `.process` flattens them and `CTFontManagerRegisterFontsForURL` fails at launch.
- **`TransitUI`** — SwiftUI blocks (`TrainBlockView`, `BusBlockView`, `MetraBlockView`, `BikeBlockView`, etc.) and viz primitives in `TransitUI/Viz/` (frequency ribbon, headway dot strip, Marey progress strip, bike availability bar).

App target (`CozyFox/`) wiring is in `CozyFoxApp.init`: bootstrap theme, prewarm catalogs, open `TransitStore`, then construct `PreferencesStore` → `LocationCoordinator` → learning stores (`WalkingDistanceStore`, `ArrivalBiasStore`, `BikeRouteStore`) → `RefreshCoordinator` → `AppViewModel` (`@MainActor @Observable`). `RefreshCoordinator` owns the API clients, the learning trackers (`ArrivalGrader`, `WalkSpeedTracker`, `BikeSpeedTracker`, `CommuteLegTracker`), and the 30 s foreground refresh loop. The widget never imports `RefreshCoordinator` — it reads the SwiftData cache directly.

`Shared/CommuteAttributes.swift` is compiled into **both** the app and the live activity target (see `project.yml`). ActivityKit requires identical type identity across the two processes, so don't move it into a library — it must be source-included in both targets.

## Conventions

- **The prediction layer stays invisible.** All the learning machinery (`ArrivalBiasStore`, `LocalPredictionEngine`, `PersonalAccessEstimator`, `ArrivalGrader`, etc.) is allowed to influence ranking, defaults, cache prefetch, filters, and which tiles are shown — but it must never produce user-facing copy ("we noticed you usually…", "predicted 3 min late"). If you find yourself writing a string that explains a prediction, that's the wrong surface; reshape state instead.
- **No street addresses in committed code, PRs, or commit messages.** Coordinates and neighborhood names are fine; specific addresses are private.
- Swift 6 strict concurrency is enabled package-wide and on the test target. Anything crossing a hop is `Sendable`; UI state lives on `@MainActor`.
- Times in domain code go through the `Clock` protocol (`SystemClock` uses `America/Chicago` + `en_US_POSIX`). Tests inject `FakeClock` rather than mocking `Date.now`.

## Pointers

- `docs/DOOR_TO_DOOR.md` — exploration notes for door-to-door multimodal prediction (uses divvy-observer's Python models locally; not yet implemented).
- Peer Python repo `../divvy-observer/` is the data-collection and modeling side; Cozy Fox consumes its outputs, never the inverse.
