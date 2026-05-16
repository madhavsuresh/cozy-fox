# Journey architecture — door-to-door uncertainty engine

> **Status: live but partial.** A single debug card on the dashboard composes a multi-leg, multimodal departure ladder from real CTA / Metra / Intercampus arrivals. Most of the layered architecture described in the original product thinking ([DOOR_TO_DOOR.md](DOOR_TO_DOOR.md)) is **not yet built or wired** — see "What's live" vs "What's substrate-only" below. This document tracks reality, not aspiration.

## What's live

Everything in this list runs each time the dashboard refreshes:

```
DepartureLadderBuilder
  ├─ JourneyComposer (Monte Carlo, seeded LCG, 128 samples per row)
  │    ├─ PreparedTransitLeg (StopArrivalProcess wait + analytic in-vehicle Gaussian)
  │    └─ PreparedWalkProcess (WalkSpeedEstimate + jitter)
  ├─ StopArrivalProcess + WaitForecast
  ├─ LineHealthAnalyzer
  ├─ TransferDetector (with service-viability gating)
  └─ DepartureLadderSnapshotAdapter (live arrivals → LiveDeparture, direction-filtered)
```

Inputs: `TransitSnapshot` (already populated by the existing `RefreshCoordinator`), `CommuteAnchors`, `UserRoutePreferences`, `WalkSpeedEstimate` from the existing `WalkingDistanceStore`. Outputs: a `DepartureLadder` with up to 5 rows.

UI surface: [DepartureLadderDebugCard](../CozyFox/Home/DepartureLadderDebugCard.swift) at the top of the dashboard, eyebrow "Debug — departure ladder".

Calibration: every rebuild appends one `JourneyEpisodeLog` to `Caches/Calibration/journey-predictions.ndjson` via the [JourneyPredictionLogStore](../CozyFox/Learning/JourneyPredictionLogStore.swift) actor. Local-only; rotates at 5MB.

## What's substrate-only

These types exist, are tested, and are not invoked at runtime. They're sketches for future phases.

- `DivvyPredictionProviding` + `DivvyPredictionStub` + `DivvyModelBundleManifest` — the shape of a Divvy provider, with constant-returning stub for tests. No real provider implementation yet.
- `PredictionLogEntry` + `JourneyEpisodeLog` — value types now written by the log store; no replay/evaluator yet.

That's it. Earlier rounds added more substrate (active-trip monitor, policy ranker, Divvy kernels, several value types) that turned out to be sketches without consumers. Those have been removed — the API will reset when the consumer for each appears, instead of carrying provisional shapes.

## What's known wobbly

If you use the card and something looks off, this is likely the cause:

1. **In-vehicle estimates are haversine ÷ per-mode speed.** L = 12 m/s + 25 s/km stop penalty; Metra = 22 m/s + 8 s/km; bus = 6 m/s + 30 s/km; Intercampus = 14 m/s + 6 s/km. No schedule data, no route geometry. For long trips on rails that don't run straight (e.g. Metra UP-N follows the lakeshore corridor), the haversine line is shorter than the actual track — the estimate is short.
2. **Walking time falls back to haversine × 0.78 s/m × your ratio** when the `WalkingDistanceStore` cache is cold for that origin/station pair. MapKit-routed walking time arrives async and only kicks in after a previous request landed in the cache.
3. **Schedule headway is hardcoded at 600s** (10 min) for L, 720s for bus, 1200s for Intercampus, 1800s for Metra. Only consulted in the stale/missing-feed fallback path. Real headways are very different across modes and time of day.
4. **Multi-leg is one transfer deep.** No chained transfers (e.g. Blue → Red transfer at Jackson, then Red → Purple at Howard).
5. **Transfer detection is geographic.** It picks the station closest (by haversine) to the second-line's alighting that serves both lines. No corridor knowledge, no schedule-aware optimization.
6. **Direction filtering uses a dot-product heuristic** over destination-name → station-coordinate lookup. Composite destinations like "Loop" don't match a single station and are conservatively kept; rare destination names that don't appear in `LStationCatalog` are also kept.
7. **The card is always on**, no Settings toggle, no way to dismiss.

## Live data path

`AppViewModel.snapshot` → `DepartureLadderDebugViewModel.rebuild(...)` is triggered on dashboard appear, on `model.snapshot` change (every 30s in foreground), and on `model.pinRevision` change.

Inside `rebuild`:

1. Load `commuteAnchors`, `routePreferences`.
2. Build up to 4 `LadderCandidateSpec`s — one per pinned mode (CTA train, Metra, bus, Intercampus). For trains, `TransferDetector` may add a second leg if the pinned-line alighting is far from Work and a viable second line exists.
3. The builder uses `JourneyComposer` to sample 128 outcomes per row. Each row carries the empirical p50 / p80 / p90 of total door-to-door duration, the failure probability, and a `WaitReasonableness` risk tag derived from the wait state and failure rate.
4. Rows are collapsed (90 s dedupe), capped at 5, miss-cost annotated, and a cliff is detected if any inter-row arrival gap exceeds 8 min.
5. A `JourneyEpisodeLog` is appended to the prediction log file.

## Privacy boundary

The original thinking distinguished server-side (public-only) from phone-side (private). Today this app has **no server** — everything runs on device, including the journey layer. Calibration logging stays local in Caches. There is currently no public-bundle ingest or schema; the server-side bundle interface was deferred.

## Testing strategy

`swift-testing` (`@Suite`, `@Test`). Per-module test targets in the package. Run:

```bash
swift test --package-path Packages/TransitCore
```

Two patterns specific to the journey layer:

- **`FakeClock` + seeded LCG.** All composer outputs are deterministic for fixed inputs. Tests that exercise the composer use `SeededLCG(seed:)` from `TransitDomain/Journey/Kernels/SeededGenerator.swift`.
- **Synthetic `TransitSnapshot`.** Hand-built snapshots with known arrivals. No HTTP, no fixtures.

End-to-end coverage: `DepartureLadderEndToEndTests` and `JourneyComposerEndToEndTests` print sample ladders to test output so you can see what changes look like.

## Roadmap pieces that did NOT land

For honesty: these were in the original product brief, are not currently planned, and were removed if previously sketched.

- **Stochastic composer with shared latents** (one `surfaceTraffic` / `weatherPenalty` / `feedTrust` drawn once per journey, applied to all legs). The composer today samples each leg independently.
- **Active trip monitor.** No actor watches the current trip phase or surfaces choice-point recommendations.
- **Policy ranker + hysteresis.** The dashboard shows whichever candidate the viewmodel built; there's no ranking step that picks "best realistic" vs "fastest if it hits" across multiple options.
- **Server bundle interface** (public operating-model bundle, GTFS priors, prediction residuals, line-health priors, calibration metadata).
- **Divvy kernels and `BikeInventoryDivvyProvider`** wired in. Stub interface exists; no real wiring.
- **Notifications / Live Activity.** No interrupts when recommendation changes.
- **Calibration evaluator.** Logs are being written; no offline replay or coverage metric tool reads them yet.
- **Destination frontier UI** — a small set of distinct-tradeoff options shown side by side. The card today shows rows from candidates the viewmodel built, sorted by leave-by; not a frontier.
- **Departure ladder UI polish.** The current card is debug-eyebrow and renders inside the existing dashboard. The "morning departure ladder" surface as described in the brief would be a primary surface.

## Module placement

All journey types live in `TransitCore`:

- **TransitModels/Journey/** — pure value types (`TimeDistributionSummary`, `JourneyPoint`, `LegCandidate`, `LegMode`, `WaitReasonableness`, `LineHealthSnapshot`, `JourneyOption`/`JourneySlot`, `DepartureLadder`/`DepartureLadderRow`, `PlannerCoordinate`).
- **TransitModels/Calibration/** — `PredictionLogEntry`, `JourneyEpisodeLog`.
- **TransitDomain/Journey/** — pure analyzers (`StopArrivalProcess`, `LineHealthAnalyzer`, `TransferDetector`) + composer (`JourneyComposer`) + adapter (`DepartureLadderSnapshotAdapter`) + builder (`DepartureLadderBuilder`).
- **TransitDomain/Journey/Kernels/** — `LegKernel` protocol, `PreparedLegProcess` protocol, `SeededLCG`, `WalkingKernel`, `TransitLegKernel`.
- **TransitDomain/Journey/Divvy/** — stub provider and bundle manifest.

App-target code lives under `CozyFox/Home/` (debug card + viewmodel) and `CozyFox/Learning/` (prediction log store).

## What this is for

Two things, in order:

1. **A working debug surface** to use on real commutes, capture what's wrong, and surface bugs. The current correctness story is good enough for that.
2. **A foundation** that real layers can be built on top of when their consumers exist. Substrate without a consumer was a mistake (it forced API choices ahead of constraints) and has been pruned.

Don't take the absence of a layer in this doc as "we decided against it". The product brief stands. We just haven't built it.
