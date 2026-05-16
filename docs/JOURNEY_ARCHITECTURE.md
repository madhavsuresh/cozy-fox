# Journey architecture — door-to-door uncertainty engine

> Status: substrate landed. This document names the layers and the boundary contracts. The exploratory product thinking ("what's hard about this", Evanston worked example, Divvy decision math) is in [DOOR_TO_DOOR.md](DOOR_TO_DOOR.md). Read that first if you want the *why*.

## What this is

Cozy Fox is becoming a destination-first, private, door-to-door uncertainty engine for veteran transit riders. The user enters a destination; the app composes a small frontier of realistic options across walk, CTA bus, CTA train, Metra, Divvy classic, Divvy e-bike, and final-mile choices; it shows each as a realistic range; it infers which option the rider is actually executing from movement; it keeps alternatives alive in the background; it interrupts only when the recommended action changes materially.

The bar is **decision intelligence, not turn-by-turn directions**:

- Can I wait?
- Should I leave now?
- Does missing this vehicle matter?
- Is waiting at this stop reasonable?
- Should I get off at Grand or stay to Chicago?
- Is the 65 in a long gap?
- Is Divvy worth the dock risk?

The app should feel like a private transit radar, not a generic route planner.

## Layers

```
SERVER SIDE (optional, public only)
-----------------------------------
public transit operating-model builder
  - GTFS / archived realtime ingest
  - realized arrival reconstruction
  - headway / wait / runtime priors
  - feed reliability models
  - line-health priors
  - calibration metadata
  - versioned bundle publisher
                │
                ▼  (distributed as local bundle)

IPHONE — PRIVATE
----------------
local public operating bundle
+ current live feeds
+ private destination, location, motion
+ private walking-speed estimate
+ private preferences + trip history
+ local Divvy model bundle
+ personal calibration overlay
                │
                ▼

per-leg probabilistic kernels
  WalkingKernel, CTABusKernel, CTATrainKernel,
  MetraKernel, IntercampusKernel,
  DivvyClassicKernel, DivvyEBikeKernel,
  FreeBikeParkingKernel, FinalMileKernel
                │
                ▼

stochastic journey composer
  - Monte Carlo over candidate journeys
  - conditional waits, missed transfers,
    dock-full fallback, no-bike fallback,
    exchangeable legs, correlated latents
  - p50 / p80 / p90 / failure probabilities
                │
                ▼

policy ranker + active session tracker
  - small frontier of options
  - implicit route-choice inference
  - active trip leg monitoring
  - choice-point monitoring
  - hysteresis, notification gating
                │
                ▼

UI
  - destination frontier
  - morning departure ladder
  - choice-point card
  - line-health chip
  - Live Activity / widget surface
  - notifications only when action changes
```

## Privacy boundary

> The server learns the city.
> The phone decides the trip.

The server, if used, learns only public system behavior from public feeds. It never learns:

- user location
- user destination
- home / work
- which route the user chose
- personal walking speed
- inferred route choice
- trip history
- notification behavior
- personal risk tolerance

The phone combines public operating priors (loaded from a versioned bundle) with private state locally. There is no backend roundtrip per trip. There is no personalized telemetry leaving the device.

## The model is not the planner

ML and statistical models live **inside kernels**, where they estimate uncertain quantities:

- wait distribution at a stop
- ETA residual
- prediction confidence
- feed reliability
- catch probability
- in-vehicle runtime distribution
- dock availability
- usable-bike probability
- e-bike ride duration
- classic-bike docking risk
- final-mile failure risk
- user preference / risk tolerance

The composer above them remains explicit, inspectable logic:

- if the user arrives after a departure, the transfer was missed
- if destination dock is full, try fallback dock or free-park (when allowed)
- if the user is not near a candidate route, reduce belief in that route
- if option A has lower p50 but much worse p90, policy decides
- if last good option is imminent, bypass ordinary hysteresis

We do not train a model to learn deterministic transit logic.

## Module layout

Everything lives in the `TransitCore` Swift package:

- **TransitModels** — pure value types, no dependencies. All journey-layer value types live in `Sources/TransitModels/Journey/` and `Sources/TransitModels/Calibration/`.
- **TransitDomain** — pure analyzers and protocols. Kernels and analyzers live in `Sources/TransitDomain/Journey/` (with `Kernels/` for the kernel implementations).
- **TransitCache** — `TransitSnapshot` and persistence. The journey layer consumes `TransitSnapshot` but does not add new persisted types here yet.
- **TransitLocation, ChicagoTheme, TransitUI** — unchanged by the substrate.

The app target (`CozyFox/`) and the widget / live-activity extensions are **not** touched by the substrate. Wiring the substrate into UI happens in later phases.

## Core domain primitives (the substrate)

The substrate is a coherent set of value types and protocols that compose. Each is `Sendable` and (where useful) `Codable`. None leak `CoreLocation` / `MapKit` types into pure structs — the project already owns a `PlannerCoordinate` value type, now in `TransitModels`.

- `PlannerCoordinate` — project-owned lat/lon (was in `TransitDomain`, promoted to `TransitModels` so journey types can carry it without an import cycle).
- `TimeDistributionSummary` — `{mean, p50, p80, p90, confidence, sampleCount}` with an `empirical(from samples:)` constructor.
- `JourneyPoint` — typed endpoint: `.anchor(home|work)`, `.coordinate`, `.stop`, `.station`, `.divvyStation`, `.namedPlace`.
- `LegMode` + `LegCandidate` — one possible way to traverse a segment.
- `WaitReasonableness` — user-meaningful wrapper: `goodWait`, `acceptableWait`, `riskyWait`, `badGap`, `bunched`, `feedUnreliable`, `unknown` — each carrying a label and a confidence tone.
- `LineHealthState` + `LineHealthSnapshot` — state of a service: `normal`, `longGap`, `bunchedThenGap`, `compressed`, `degraded`, `recovering`, `feedStale`, `insufficientData`.
- `JourneySlot` + `JourneyOption` — a candidate door-to-door option. Slots are `.fixed(LegCandidate)` or `.exchangeable(alternatives:policyHint:)` to support deferred choice points.
- `ChoicePoint` — a decision not yet committed: location, decision time, candidates, recommendation, hysteresis hold, confidence.
- `DoorToDoorRequest` + `DoorToDoorPrediction` — request and response for the composer.
- `DepartureLadderRow` + `DepartureLadder` — the morning-ladder model: next leave-by opportunities, arrival ranges, headline, cliff, line-health annotations.
- `ActiveTripSession` — runtime state after a destination is known: phase, candidate options, option beliefs, inferred option, pending choice points, current recommendation, last update.
- `LegWatchPriority` + `LegRefreshPolicy` + `LegWatch` — a watched leg in the active-trip monitor.
- `PredictionLogEntry` + `JourneyEpisodeLog` — calibration scaffolding. No IO and no evaluator yet, but the shape exists so we can start logging without a schema migration.

## Domain analyzers (also substrate)

These live in `TransitDomain/Journey/`. They are pure, Sendable, off-actor.

- `LegKernel` (protocol) + `PreparedLegProcess` (protocol) + `LegOutcome` — the two-stage kernel API. `prepare` does the expensive work (table lookup, feed lookup, Core ML inference). `sample` is cheap and deterministic given a seeded RNG.
- `SeededLCG` — a tiny linear-congruential `RandomNumberGenerator` for deterministic tests.
- `WalkingKernel` — first concrete kernel. Conforms to `LegKernel`. Takes a MapKit-expected walking time, a `WalkSpeedEstimate` (Welford-tracked, already in the codebase), and an optional jitter coefficient.
- `StopArrivalProcess` + `WaitForecast` — given upcoming live departures, schedule headway, and feed state, produces a wait-time distribution and a `WaitReasonableness` state for a hypothetical arrival time. This is the core query "if I arrive at the stop at time t, is it reasonable to wait?"
- `LineHealthAnalyzer` — given recent arrivals + baseline headway, returns a `LineHealthSnapshot`. Detects normal / longGap / bunchedThenGap / feedStale / insufficientData. Leans on the existing `HeadwayBunchingDetector` for the bunching detail.

## First vertical slice — DepartureLadderBuilder

The user's most-used surface is "if I leave home at the next few useful opportunities, when will I arrive door-to-door?" — answered as a small ladder, not a list of trains. `DepartureLadderBuilder` is the first composer that uses the substrate end-to-end:

- input: origin (`JourneyPoint`), destination (`JourneyPoint`), `TransitSnapshot`, candidate first-leg specs (provided by the caller), `WalkSpeedEstimate`, a walking-time fetcher closure, a `Clock`.
- behavior:
  1. for each candidate spec, derive a `StopArrivalProcess` and a `LineHealthSnapshot` from the snapshot;
  2. enumerate next ~10 live departures per candidate;
  3. for each one, compute leave-by, arrival distribution, primary/secondary labels, risk;
  4. sort by leave-by, dedupe near-identical windows, drop dominated rows;
  5. detect the arrival cliff (first inter-row arrival gap > 8 min);
  6. annotate the headline only when a cliff exists;
  7. return the top five rows.
- output: a `DepartureLadder` value type with `headline`, `nextCliffAt`, `rows`, `lineHealth`.

This is pure logic, fully deterministic with `FakeClock` and seeded RNG.

## What does NOT exist yet (deliberately)

The substrate is the foundation, not the full vision. These layers will land in subsequent phases:

- **Other concrete kernels** (`CTATrainKernel`, `CTABusKernel`, `MetraKernel`, `DivvyClassicKernel`, `DivvyEBikeKernel`, `FreeBikeParkingKernel`, `FinalMileKernel`). The protocol is there; implementations will arrive incrementally.
- **Stochastic journey composer.** The Monte Carlo composition over `JourneyOption` with shared latents is the heart of the policy layer. Not in the substrate.
- **Policy ranker + hysteresis.** The existing `PortfolioHysteresis` and `RouteOptionScorer` are precedents we'll lean on; a journey-level analogue lives in a later phase.
- **`ActiveTripMonitor` actor.** The session state shape exists; the actor that updates it from live data does not yet.
- **Divvy model bundle.** A `DivvyPredictionProviding` protocol and a `DivvyModelBundleManifest` value type will land alongside the Divvy kernels.
- **Server bundle loader.** Phone-side protocol for consuming a versioned public operating-model bundle is a separate phase.
- **Calibration evaluator.** Logging shapes exist; the offline replay harness and reliability-diagram tooling do not yet.
- **UI integration.** No dashboard card / widget / Live Activity surface yet for the new layer.

## Testing strategy

Everything in the substrate is testable without simulator, without network, without Xcode-project regeneration. The repo standard is `swift-testing` (`@Suite`, `@Test`) and `FakeClock`. The journey layer adds two patterns:

- **Seeded RNG.** `SeededLCG` is a small linear-congruential generator. Tests that exercise a kernel's `sample` method use a fixed seed so the outcome is reproducible.
- **Synthetic `TransitSnapshot`.** Tests construct a hand-built snapshot with known arrivals, then assert exact ladder shape. No HTTP, no fixtures, no decoding.

End-to-end coverage for the first vertical slice is one `DepartureLadderBuilderTests` case that:

- builds a synthetic snapshot (one Red Line station, two candidate first-leg specs, Home → Work),
- invokes the builder with `FakeClock` and a deterministic walking-time stub,
- asserts row count, leave-by ordering, cliff presence, and headline copy.

Pass criteria for any new journey work:

```
swift test --package-path Packages/TransitCore
```

All pre-existing tests (413 across 62 suites at substrate-land time) still pass; new tests cover the new substrate.

## Implementation constraints

- Strict Swift 6 concurrency. `Sendable` on every public type. No `MainActor` annotations in pure domain types. Where shared mutable state is needed (it isn't, in the substrate), use an actor in `TransitDomain` — never in `TransitModels`.
- No `MapKit` / `CoreLocation` imports in `TransitModels`. Cross-module callers convert via `PlannerCoordinate.clLocationCoordinate`.
- Value types throughout. No classes, no inheritance.
- Default to writing no comments. The repo style explicitly avoids descriptive comments; only the *why* of a hidden constraint earns a line.
- No edits to `CozyFox/Home/DashboardScreen.swift`. Domain logic stays in the package; the dashboard wires it in a later phase.
- No edits to `Package.swift`. SPM auto-discovers new files in existing target source directories.

## What this earned us

After the substrate lands:

- We can sample a walking leg deterministically.
- We can compute a wait-distribution conditional on hypothetical arrival time at any CTA / Metra / Intercampus stop.
- We can detect line-health states from live arrivals.
- We can build a `DepartureLadder` end-to-end and assert exact rows in a test.

Next sequential conversations build on this: wire `DepartureLadderBuilder` into the dashboard as a debug card; add `CTATrainKernel` and `CTABusKernel`; add the stochastic composer; introduce the active-trip monitor actor; add the Divvy bundle protocol; finally surface the destination frontier in the UI.
