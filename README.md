# Cozy Fox

A glanceable Chicago transit dashboard for iPhone. CTA trains, CTA buses, Metra, and Divvy e-bikes on your home screen — context-aware to where you are, privacy-respecting, no backend.

## Requirements

- macOS with Xcode 26+
- iOS 26 device (or simulator) for full Liquid Glass widgets and Live Activities
- Free API keys: [CTA Train Tracker](https://www.transitchicago.com/developers/traintrackerapply/) and [CTA Bus Tracker](https://www.transitchicago.com/developers/bustracker/)
- Optional realtime key: [Metra GTFS Realtime](https://metra.com/gtfs-realtime-api-key-request-license-agreement)

Metra schedules and Divvy GBFS are public and need no auth.

## Quick start

```bash
brew install xcodegen           # if not already installed
xcodegen generate               # produces CozyFox.xcodeproj
open CozyFox.xcodeproj
```

Then in Xcode:

1. Select the **CozyFox** scheme and a real device (Live Activities and region monitoring don't work in the simulator).
2. In **Signing & Capabilities** for each target (CozyFox, CozyFoxWidget, CozyFoxLiveActivity), pick your Apple ID team. The bundle IDs are pre-set to `net.thoughtbison.cozyfox*`.
3. Build & run. On first launch, the onboarding flow asks for your CTA API keys, optional Metra realtime key, Home + Work locations, and your usual routes.

## Architecture

See [docs/PLAN.md](docs/PLAN.md) (the architecture is also summarized in `/Users/madhav/.claude/plans/i-want-to-build-cozy-fox.md`).

Top level:

- `Packages/TransitCore/` — pure Swift package, all the data + domain + reusable UI. Has its own tests.
- `CozyFox/` — iPhone app target.
- `CozyFoxWidget/` — WidgetKit extension.
- `CozyFoxLiveActivity/` — ActivityKit extension.

## Tests

```bash
swift test --package-path Packages/TransitCore
```

All API clients have fixture-driven decoder tests; domain logic has unit tests. The widget views have snapshot tests behind the `swift-snapshot-testing` dep (added on first run).

## Privacy

Cozy Fox has no backend. Your phone talks directly to:

- `gbfs.lyft.com` for Divvy data (public, no auth)
- `lapi.transitchicago.com` for CTA train arrivals (your API key)
- `ctabustracker.com` for CTA bus arrivals (your API key)
- `schedules.metrarail.com` for bundled Metra schedules (public)
- `gtfspublic.metrarr.com` for Metra realtime updates, vehicle positions, and alerts (your Metra key, if set)
- `transitchicago.com/api/1.0/alerts.aspx` for CTA alerts (public)

Location is only used for:
- Region monitoring around your set Home and Work (entry/exit events; no continuous tracking)
- A one-shot foreground update when you open the app or refresh

API keys live in the shared app-group defaults store, scoped to the app + widget access group.
