# On-device bus arrival reliability + calibration

> Status: idea capture, 2026-05-17. Sister doc to [CONFIDENCE_INTERVALS.md](docs/CONFIDENCE_INTERVALS.md) (the north-star metric this work is judged against) and [SYNTHETIC_ROUTES.md](docs/SYNTHETIC_ROUTES.md) (the data-collection harness this work composes with). Trigger: the #65 didn't show up at Grand & McClurg one weekday evening, and BusTime kept showing the bus was "DUE" while no bus was anywhere near the stop.

## The motivating failure

CTA Bus Tracker returns `prdtm` (predicted arrival time) and `getvehicles` returns live vehicle positions, but the two are not validated against each other inside BusTime itself. Failure modes the app currently shows uncritically:

- **Ghost predictions** — a prediction with a `vid` whose corresponding vehicle is stale or absent from `getvehicles`. BusTime keeps emitting it; rider waits.
- **DUE-but-far** — `prdtm` says one minute, the actual vehicle is 1.5 mi away or on a different pattern.
- **Already-passed** — `pdist` of the vehicle is past the stop's pattern-distance, but the prediction still appears.
- **Detoured stop** — the stop is on the active detour's `dtrrem` list but predictions still show.
- **Cancelled / expressed / invalidated trips** — `dyn` codes 1, 4, 12, 16, 17, 18 etc. Today we ignore `dyn` entirely.

What we have today: `BusBlockView` renders `BusPrediction` as a `BigNumber` plus a dot strip, with no per-prediction reliability signal. `ArrivalGrader` correlates predictions to vehicles after the fact, writing aggregate bias deltas. There's no real-time abstain path; whatever CTA says is what shows on screen.

## What we want

Two layers, related but separate:

1. **Per-prediction reliability scorer.** Joins the existing `BusPrediction` with the existing `CachedVehiclePosition` (and, later, pattern geometry and detour state). Emits a discrete reliability state and a set of reason codes per arrival. Drives ranking, filtering, and styling — *never* user-facing copy, per [feedback_cozyfox_invisible_predictions](feedback_cozyfox_invisible_predictions.md). Some arrivals get hidden; some get muted; the ones that show are the ones we have evidence for.
2. **On-device empirical calibration.** Records every CTA prediction snapshot's residual against the eventual confirmed arrival, binned by (route, stop, horizon, hour-of-week). Per-bin empirical quantiles (q10, q50, q90) feed bias correction and prediction intervals. This is exactly the `calibration_residual_quantile` table from the Python prototype reference — built on top of the existing [`ArrivalBiasStore`](Packages/TransitCore/Sources/TransitDomain/ArrivalBiasStore.swift), not as a parallel system.

The two compose: the scorer says "this prediction is reliable enough to display"; the calibrator says "this prediction's q50 residual on this stop at this horizon at this hour is +90s, so shift it." Scorer is qualitative state; calibrator is a quantitative shift + interval.

## Per-prediction reliability scorer

### Data the scorer reads

All already in the cache today, no new endpoints required for v1:

- The `BusPrediction` itself (`vehicleId`, `route`, `directionName`, `stopId`, `arrivalAt`, `isDelayed`, `generatedAt`)
- `CachedVehiclePosition` joined by `vehicleId` (latest observation: lat/lon, observedAt, fetchedAt, route, heading)
- The CTA server-time anchor (from `gettime`, *not* currently fetched — add it)
- The target `BusStop`'s lat/lon (already in `Catalogs`)

Additions that come in later phases: pattern points (route geometry) and detour state.

### Reason codes (subset of the CTA prototype's set, trimmed to what we can actually compute)

Negative:
- `VEHICLE_NOT_FOUND` — `vid` in prediction has no recent observation in `CachedVehiclePosition`. Strong negative.
- `VEHICLE_STALE` — observation is older than ~120 s (configurable per polling cadence).
- `DUE_BUT_VEHICLE_NOT_NEAR_STOP` — `eta_s ≤ 90` but haversine distance from latest vehicle position to stop > 350 m and the vehicle observation is fresh. The cleanest ghost detector available without pattern geometry.
- `ROUTE_MISMATCH` — vehicle's `rt` doesn't match prediction's `rt` (rare but happens when BusTime reassigns).
- `PREDICTION_STALE` — `generatedAt` is more than 120 s before the CTA server-time anchor; CTA hasn't refreshed.
- `DLY_TRUE` — `isDelayed` set; minor downweight, doesn't abstain on its own.

Positive:
- `VEHICLE_FRESH` — observation ≤ 60 s old.
- `VEHICLE_NEAR_STOP_AT_DUE` — `eta_s ≤ 180` and vehicle within ~300 m. Strong positive.
- `ROUTE_MATCH`.

Later, with pattern geometry (phase 3):
- `PDIST_INCREASING`, `PDIST_CROSSED_STOP`, `PATTERN_MATCH`, `CTA_GEOMETRY_AGREE` / `DISAGREE`, `GPS_ON_EXPECTED_PATTERN`.

Later, with detours (phase 2):
- `STOP_REMOVED_BY_DETOUR` (abstain), `STOP_ADDED_BY_DETOUR`, `DETOUR_ACTIVE`.

### Output

```swift
public struct BusArrivalReliability: Sendable {
    public enum State: Sendable {
        case highConfidence   // show normally
        case mediumConfidence // show normally
        case lowConfidence    // show in muted style
        case unreliable       // hide unless explicitly debugging
        case doNotDisplay     // remove from the row entirely (abstain)
    }
    public let state: State
    public let score: Double                  // 0...1, for ranking ties
    public let reasonCodes: [String]          // for the debug surface only
    public let suggestedDisplayMinutes: Int?  // nil when abstaining
}
```

No `rider_message` field. That's the Python prototype's interface for a server-mediated client; in Cozy Fox the rule is that the prediction layer never produces user copy. If a prediction is `doNotDisplay`, the row just doesn't render — same outcome the user would experience if CTA had never emitted that prediction.

### Where it lives

Pure function over a `Clock`, in `Packages/TransitCore/Sources/TransitDomain/BusReliabilityScorer.swift`. Inputs: a `BusPrediction`, the latest matched `VehiclePosition` (or nil), the target stop coordinates, the CTA server-time anchor, and a config struct (thresholds). Output: `BusArrivalReliability`. No I/O, no async, no actor — testable with `FakeClock` and fixtures.

Wired in `RefreshCoordinator.refreshBuses()` after the parallel `fetchPredictions` + `fetchVehicles` complete. The scored result is cached alongside the prediction; `BusBlockView` reads the state and filters / styles accordingly.

## On-device empirical calibration

### What gets stored

Two layers, both bounded:

1. **Raw residuals** (last ~30 days, only for routes/stops the user actually rides — pinned + frequently glanced). A new SwiftData `@Model` in `TransitCache`:

    ```swift
    @Model final class BusPredictionResidual {
        var route: String
        var directionName: String
        var stopId: String
        var horizonBucket: HorizonBucket   // 0-2m, 2-5m, 5-10m, 10-20m, 20m+
        var hourOfWeek: Int                // 0...167
        var ctaPredictedAt: Date           // generatedAt
        var ctaPredictedArrival: Date      // arrivalAt
        var confirmedArrival: Date         // from ArrivalGrader
        var residualSeconds: Double        // confirmed - predicted
        var reliabilityStateAtPrediction: String  // scorer's verdict at that snapshot
    }
    ```

    Compacted nightly: rows older than 30 d are deleted after their contribution lands in the aggregate.

2. **Aggregated quantile bins** (kept forever, bounded total size). Extends the existing `ArrivalBiasStore` cell model rather than introducing a parallel store:

    ```swift
    @Model final class BusResidualQuantileBin {
        var route: String
        var directionName: String
        var stopId: String
        var horizonBucket: HorizonBucket
        var hourOfWeek: Int
        var n: Int                  // sample count
        var q10Seconds: Double
        var q50Seconds: Double
        var q90Seconds: Double
        var lastUpdated: Date
    }
    ```

    Updated incrementally as new raw residuals land. P² quantile estimator (or just full re-sort on the bin's last N raw rows) — at one user's volume per bin, recomputing is trivial.

### What "confirmed arrival" means on device

This is the part where on-device differs from the Python prototype. The prototype confirms arrivals via `pdist` crossing (requires pattern geometry, phase 3). On device today, we already have a weaker but workable signal in `ArrivalGrader`: vehicle observed within a small radius of the stop, monotone-decreasing distance, then either disappearing or reappearing on the other side.

For phase 4 calibration we accept that weaker confirmation as ground truth, with a `confirmation_quality` flag (`pdist_crossing` > `lat_lon_passby` > `disappearance`). Bins built from low-quality confirmations are kept but flagged; the scorer / interval logic can downweight them.

When phase 3 lands (pattern geometry for pinned routes), those routes get high-confidence confirmations and tighter bins. The data shape doesn't change; only the `confirmation_quality` distribution does.

### How it feeds the real-time path

At display time, for each `BusPrediction` that the scorer passes:

1. Look up the matching `BusResidualQuantileBin` for `(route, directionName, stopId, horizonBucket, hourOfWeek)`.
2. Fall back to coarser bins on miss: drop `hourOfWeek` first, then drop `directionName`, then drop `stopId` (route-wide), then a global default.
3. Shift the displayed minutes by `q50 / 60` (rounded) — small, usually sub-minute correction.
4. The (q10, q90) gives an interval. We don't surface it as text, but it gates whether the BigNumber is the right summary: when the band is wider than ~3 minutes, we should be showing a range or muting the number, not committing to a single-digit count.

This intentionally mirrors what the [confidence-interval north star](docs/CONFIDENCE_INTERVALS.md) calls out as the operating contract: calibration first, sharpness second, never confidently extrapolate when data is thin.

## Where this fits in existing infrastructure

- **[`CTABusClient`](Packages/TransitCore/Sources/TransitAPI/CTABusClient.swift)** — already calls `getpredictions` + `getvehicles`. Phase 1 needs nothing new. Phase 2 adds `getdetours` + `getenhanceddetours` (~5 min cadence). Phase 3 adds `getpatterns` (startup + on detour change, scoped to pinned routes).
- **[`BusPrediction`](Packages/TransitCore/Sources/TransitModels/BusPrediction.swift)** — already has the fields. Add the scored `BusArrivalReliability` as a separate attached value, not a stored property on the prediction (predictions are decoded from upstream; the reliability is computed locally).
- **[`CachedVehiclePosition`](Packages/TransitCore/Sources/TransitCache/CachedModels.swift)** — already there. Phase 1's scorer joins by `vehicleId`.
- **`BusBlockView`** in `Packages/TransitCore/Sources/TransitUI/` — takes `[BusPrediction]` today. Updated to take `[(BusPrediction, BusArrivalReliability)]`, filter `doNotDisplay`, mute `lowConfidence`/`unreliable`. The `BigNumber` is suppressed when the top result is muted; users see the dot strip or schedule fallback instead. (Compare `IntercampusBlockView`'s adaptive density per [feedback_adaptive_density](feedback_adaptive_density.md): live + schedule layered, schedule is always there.)
- **[`ArrivalGrader`](CozyFox/Learning/ArrivalGrader.swift)** — already ingests bus predictions and positions. Extended to also emit `BusPredictionResidual` rows when a prediction's vehicle is confirmed at the stop. Does not change its existing `ArrivalBiasStore` writes; that store keeps doing its job.
- **`RefreshCoordinator.refreshBuses()`** — adds two steps: (a) score each prediction, attach reliability; (b) on confirmed-arrival callback from grader, write a residual row.

Nothing in this proposal duplicates existing machinery. The scorer is new logic over existing data; the residual store is a new table next to an existing one; both compose with `ArrivalGrader` rather than replacing it.

## Phases

Sized for one weekend each except where noted.

**Phase 1 — scorer over existing data.** New `BusReliabilityScorer`, wired into `RefreshCoordinator.refreshBuses()`. `BusBlockView` filters / mutes by state. Reason codes visible on the debug surface (once that exists per `CONFIDENCE_INTERVALS.md`). Catches the #65 Grand & McClurg ghost case. No new endpoints, no new storage. *Weekend.*

**Phase 2 — detours.** Add `getdetours` + `getenhanceddetours` polling at ~5 min cadence to `CTABusClient`. New `Detour` and `EnhancedDetour` SwiftData models. Scorer adds `STOP_REMOVED_BY_DETOUR` (abstain) and `DETOUR_ACTIVE` (warn). *Weekend.*

> **Phase 2a landed 2026-05-17 (commit pending).** v2 `getdetours` polling at 5 min cadence; `BusDetour` model + `CachedBusDetour` SwiftData entity; scorer emits `DETOUR_ACTIVE` reason code with a -0.10 score downgrade when an active detour matches `(route, direction)` at the current time. No abstain — the rider still gets the prediction; the band is just wider.

> **Phase 2b landed 2026-05-17 (commit pending).** Stop-removed-by-detour abstain. Added a v3 base URL on `CTABusClient` (the rest of the client stays on v2 — switching everything over is a separate cleanup) and a new `fetchStopDetourStates(stopIds:)` method that hits v3 `getstops` and extracts each stop's `dtradd` / `dtrrem` arrays. `BusStopDetourState` value type + `CachedBusStopDetourState` SwiftData entity + `TransitSnapshot.busStopDetourStates` + scorer wiring. Scorer abstains (`STOP_REMOVED_BY_DETOUR`) when the prediction's stop has any *active* detour in its `dtrrem` list, regardless of other evidence — this is the failure mode the rider can't recover from at the bus stop. Inactive detours and `dtradd`-only stops correctly pass through.

**Phase 3 — pattern geometry for pinned routes only.** Add `getpatterns` polling at startup + hourly + on detour-version change, scoped to the set of pinned + recently-glanced routes (typically < 15 routes per user). Pattern points stored as SwiftData. Scorer adds `PDIST_*`, `PATTERN_MATCH`, `CTA_GEOMETRY_*` reason codes. The "DUE-but-not-near-stop" detector upgrades from haversine to pattern-distance, which is much more accurate. Geometry ETA from `(stop_pdist - vehicle.pdist) / recent_median_speed` becomes available as an independent estimate; blended with CTA ETA per the prototype's `cta_weight` logic. *Multi-week.*

> **Phase 3a landed 2026-05-17 (commit pending).** `getpatterns` polling at an hourly cadence (and immediately when the pinned-route set grows), scoped to the routes the user actually rides. `BusPattern` / `BusPatternPoint` models + `CachedBusPattern` SwiftData entity. `VehiclePosition` gained `patternId` + `patternDistanceFeet` (CTA `pid` + `pdist`), now decoded from the v2 vehicles feed. New `BusPatternGeometry` helper handles map-match (haversine + planar-projection segment fit) and along-pattern remaining distance. Scorer gained five reason codes — `patternMatch` / `patternMismatch`, `pdistCrossedStop`, `gpsOnExpectedPattern` / `gpsOffExpectedPattern` — and now does pattern-based DUE-but-far when the vehicle has pdist + the pattern is cached, falling back to haversine otherwise. `PDIST_CROSSED_STOP` is a new abstain (the "this bus already came" case the haversine check couldn't catch).

> **Phase 3b landed 2026-05-17 (commit pending).** Geometry ETA blend. `BusVehicleHistorySample` value type + an in-memory per-bus ring buffer (~8 samples per vehicle, 12 min TTL) on `RefreshCoordinator`, mirrored to `AppViewModel.busVehicleHistory`. New `BusGeometryBlender` helper computes a robust median speed (drops zero / negative deltas and out-of-bounds samples) and a geometry ETA from `(stop_pdist - vehicle.pdist) / speed`, then blends with CTA's ETA per the prototype's `cta_weight` logic: 0.68/0.32 toward CTA when they agree (Δ ≤ 75 s), re-weighted to 0.25 CTA when CTA says DUE but geometry says > 3 min (the ghost shape). Wired into `displayableBusPredictions` before calibration (medium/high-confidence rows only). `LiveActivityCoordinator` stays on the calibration-only path — the LA reads SwiftData and history is in-memory; persisting it is a future iteration. **Phase 2b (`STOP_REMOVED_BY_DETOUR`) still pending.**

**Phase 4 — calibration store.** New `BusPredictionResidual` raw table + `BusResidualQuantileBin` aggregate table. `ArrivalGrader` writes residuals on confirmed arrivals. Nightly compaction job runs aggregation. `RefreshCoordinator` applies the per-bin q50 shift when scoring is `mediumConfidence` or `highConfidence`. This is where predictions start being personally calibrated. *Weekend for the schema, ongoing soak for the data.*

> **Phase 4a landed 2026-05-17 (commit pending).** Storage + write path: `BusPredictionResidual` and `BusResidualQuantileBin` value types in `TransitModels`, `CachedBusPredictionResidual` and `CachedBusResidualQuantileBin` SwiftData entities, `TransitStore.recordBusResidual / residualBin / allBusResidualBins / allBusResiduals` methods. Bins are recomputed by linear-interp quantile on every write (cheap at one user's volume; no nightly compaction needed yet). `ArrivalGrader` gained an optional `residualRecorder` closure that fires *only* for bus resolutions (filters out trains by checking `LineColor(rawValue:) == nil`) and is wired in `RefreshCoordinator` to call `store.recordBusResidual`.

> **Phase 4b landed 2026-05-17 (commit pending).** Apply path: `BusPredictionCalibrator` in `TransitDomain` with the 4-level fallback hierarchy (exact → drop hour-of-week → drop direction → drop stopId, all preserving route + horizon bucket). `TransitSnapshot` gained a `busResidualBins` field that `SnapshotReader` populates from the SwiftData store. `AppViewModel.displayableBusPredictions` and `LiveActivityCoordinator` now apply the per-bin q50 shift **only when the reliability scorer's state is `highConfidence` or `mediumConfidence`** — `lowConfidence` / `unreliable` already mute the BigNumber, so shifting them would paper over the uncertainty. Minimum-samples gate (default 5) drops a bin if the count is below threshold and steps to a coarser stratum instead. **Raw row pruning + a debug surface + hold-out validation are still deferred.**

**Phase 5 — interval-aware display.** When a prediction's `(q10, q90)` band is wide, suppress the BigNumber in favor of either a range or a muted style. This is the point where the [confidence-interval north star](docs/CONFIDENCE_INTERVALS.md)'s "cold corridors widen, they don't lie" actually shows up on screen. Probably needs design iteration; not a one-weekend job.

## Acceptance / targets

- **Phase 1:** the #65 ghost-bus class of failure no longer surfaces in the app. Specifically: any prediction where (vehicle observation is fresh AND distance-to-stop > 350m AND eta ≤ 90s) is reliably classified as `unreliable` or `doNotDisplay`. Verify by replaying captured prediction+vehicle pairs from real refreshes (no new collection harness needed — the existing cache already has the data after a few days of use).
- **Phase 2:** during an active detour, predictions for `dtrrem` stops do not display. Test against a real detour (use the corridor inventory in `transit-observer` to find a current one; if none active, fixture-based test).
- **Phase 3:** for pinned routes, geometry-only ETA agrees with CTA ETA within 75 s on > 80% of fresh predictions. Disagreement cases are where the value is — those are where the scorer's `CTA_GEOMETRY_DISAGREE` either widens the interval or downweights CTA.
- **Phase 4:** per-bin q50 shift improves point-prediction MAE by ≥ 15% on the user's pinned-route bins after 4 weeks of soak. Measured by holding out the last 7 days, applying the shift learned from the prior 21, comparing against unshifted CTA. Honest acceptance: shift only counts if it survives a hold-out test, not if it just fits the training bin.
- **Phase 5:** when the prediction-coverage CI from `CONFIDENCE_INTERVALS.md` is wide, the display no longer shows a confident BigNumber.

## Tradeoffs worth being explicit about

- **Per-user data is sparse.** A typical rider sees the same stop twice a day. Six months of data ≈ ~300 confirmed arrivals at a frequently-used stop, spread across many `(horizon, hour)` bins. Calibration converges in weeks, not days, and only for stops the user actually rides. This is fine for the user's own stops; it does nothing for cold corridors. Cold corridors are what `SYNTHETIC_ROUTES.md` and the peer observer projects are for.
- **The Python prototype's full schema is overkill on device.** We do not want the immutable `api_poll` log; we don't need to replay 30 days of raw responses. Aggregated bins + bounded raw window are enough.
- **No backend.** The Python prototype assumes a server polls 24/7 and serves the iOS app. We don't have that, by design. The consequence: phase 4 calibration only ever sees data when the app is foregrounded and refreshing. That's also fine — the calibrator's job is to correct *what we show the user*, and we only show the user something when the app is on.
- **Phase 3 is the expensive one.** Pattern geometry per route is non-trivial — the data is large (~10–50 KB per route worth of pattern points), and map-matching adds cost per refresh. Doing this for every CTA bus route citywide is the wrong scope. Pinned + recently-glanced routes only is the right scope and keeps memory bounded.
- **The reliability state is not a probability.** It's a discrete state intended to drive display. The numeric `score` is for ranking ties and for the debug surface. We do *not* expose it as a percent on the user-facing screen — that would violate the invisible-predictions rule, and at one rider's data volume the score's calibration as a probability is shaky.
- **`vid` reassignment.** BusTime occasionally hands a `vid` to a different physical bus mid-trip (`dyn=2`). The scorer should treat changed `tablockid` / `tatripid` as a route-mismatch signal; phase 4 calibration should be careful not to bind residuals to `vid` directly.

## Open questions

- **Where to wire `gettime`.** The CTA server-time anchor matters for prediction-age and DUE-but-far thresholds. Cheapest: cache the latest server-time-offset (Δ between local clock and CTA server clock) once per refresh cycle; reuse for all calculations in that cycle. Probably one extra HTTP call every 30 s, batched with the existing predictions/vehicles fetch.
- **Threshold tuning without a backend.** The Python prototype's thresholds (60s/120s for freshness, 350m for DUE-but-far, 75s for CTA/geometry agreement) come from soak data. Start with the prototype's values; let phase-4 residuals reveal which thresholds need adjustment per-route.
- **Where the debug surface for reason codes lives.** Per `CONFIDENCE_INTERVALS.md`, behind a long-press or DEBUG flag. Probably a tab on the trip log surface once that exists.
- **Sharing with `transit-observer`.** The peer observer project already collects CTA data at scale. Two-way contract: (a) the app emits a "where my CIs are widest" report (per `CONFIDENCE_INTERVALS.md`) so the observer biases collection toward those buckets; (b) the observer publishes per-bin priors as a small JSON the app can use as a base prior before the user has personal data. Same shape as the `SYNTHETIC_ROUTES.md` daily-refresh payload — bus residual bins are a natural extension.
- **Failure mode when the `vid` changes but the trip is the same.** A real bus, a single physical trip, but CTA renumbered the vehicle mid-route. Does the residual still belong to the same `(route, stop, horizon, hour)` bin? Probably yes — bin keys do not include `vid`. Worth re-examining once we see how often this happens in practice.
- **Compaction policy.** When does the raw `BusPredictionResidual` row get deleted after its aggregate update lands? After N days, or after the bin's `n` crosses a threshold? Probably 30 days + minimum-N safety: keep the raw row until the bin has ≥ 30 samples or 30 days pass, whichever comes first.
- **Storage budget.** Estimated: ~5–10 active routes × ~10 stops × ~5 horizon bins × 168 hour-of-week bins ≈ 40k bins maximum; at ~80 bytes per bin row ≈ 3 MB. Raw residuals at ~150 bytes × maybe 5k rows in a 30-day window ≈ 1 MB. Comfortably under any reasonable budget.

## Future work

### Temporal confidence telemetry (TODO)

> Captured 2026-05-17 during dogfooding. Trigger: watching the debug overlay live and noticing a single prediction's score visibly oscillate over consecutive 30 s refresh ticks — for example, dropping from `H 0.81` to `M 0.62` and back to `H 0.77` as the matched vehicle's age crosses freshness thresholds, the prediction's `generatedAt` ages past its own staleness cutoff, then a new prediction snapshot arrives.

> ⚠️ **The proposals below are sketches, not designs.** Hysteresis vs. memoryful scoring vs. per-stop priors are three different bets with very different implementation costs, edge cases, and failure modes — and the `expected_volatility ∝ (1 − stop_pdist_fraction)` toy model in the route-position sub-section is a guess, not a calibrated relationship. Don't implement any of them yet. The only thing that should land before serious design work is the **logger** (sample payload + bounded sink). Once we have weeks of real trajectories, the data picks the fix; until then these notes are captured thinking, not a plan.

You'd expect confidence in a given arrival to be *monotonic* over time. As the bus gets closer to the stop and we accumulate more observations, our certainty should only go up (or stay flat). In practice that's not what the scorer produces. Real-world causes I've already seen:

- **Vehicle observation aging out and refreshing.** `VEHICLE_FRESH` (+0.18) flips to `VEHICLE_STALE` (−0.30) at the 120 s threshold; the next `getvehicles` poll brings the row back to fresh. A 0.48-point oscillation on a single threshold crossing.
- **Prediction `generatedAt` aging similarly.** `PREDICTION_FRESH` (+0.06) → `PREDICTION_STALE` (−0.18) at the same cadence, slightly out of phase with the vehicle.
- **`dyn` state flipping mid-trip.** A bus enters layover (`dyn=18`) at a transfer point, then exits; the scorer downgrades by 0.25 and then restores it.
- **Pattern match becoming available.** Until the matching `BusPattern` is cached for the vehicle's `pid`, the scorer falls back to haversine; once the pattern lands, the reason codes shift from haversine-based to pattern-based, and the score moves accordingly.
- **DUE-but-far flipping near the boundary.** The 350 m / 1000 ft thresholds are knife-edge — a vehicle hovering near the cutoff can toggle the abstain repeatedly until it clearly enters or exits.

Some of this is *correct* — a layover genuinely *should* drop confidence, and pattern match becoming available genuinely *should* raise it — but a lot of it is **threshold flicker**: the score crosses a discrete reason-code boundary in a way that's noisy rather than informative. A monotonic (or at least monotone-with-justified-exceptions) score is the right target. Getting there probably requires:

- **Smoothing thresholds via hysteresis or soft transitions.** Replace the freshness step function with a smooth decay (e.g. `max(0, 1 - age/staleAge)`-shaped weight) so the score doesn't jump at a single tick.
- **Memoryful scoring.** Instead of re-deriving the score from scratch each tick, track `(min, max, last)` over the prediction's lifetime so the surfaced state can't regress past evidence we previously had. The user mostly cares about "do we still believe in this bus?" — a temporarily-stale GPS shouldn't reset our prior confidence.
- **Per-reason-code monotonicity rules.** Some signals are inherently monotonic: `PDIST_CROSSED_STOP` only ever goes from false→true. Others (`VEHICLE_FRESH`) shouldn't be allowed to *raise* confidence after they previously *lowered* it on the same prediction — once stale, the scorer has been told the upstream isn't perfectly tracking; pretending otherwise is the failure mode.

Before any of that, we need data. A logger:

- **Trigger.** Every refresh tick where `displayableBusPredictions` is computed.
- **Sink.** Local SwiftData table (`BusReliabilityScoreSample`?) keyed by `(predictionId, sampledAt)`. Bounded — only retain samples for predictions whose `arrivalAt` is within the last hour or two, then drop. Pruned aggressively because this is observability, not training data.
- **Payload.** `(predictionId, sampledAt, state, score, reasonCodes, etaSecondsAtSample)`. Maybe also matched-vehicle id + observation age so the cause of state changes is reconstructible without a second join.
- **Surface.** A new debug screen (or a long-press affordance on the dot strip) that picks a single prediction and renders its score trajectory as a sparkline over time, with reason-code transitions annotated. Same invisible-predictions rule applies — this is debug, never user-facing copy.
- **Composes with `BusReliabilityDebugLogger`.** That one logs to `os_log` per-cycle for live tailing; this one persists per-prediction for after-the-fact analysis. The two coexist.

Acceptance: after one week of dogfooding, the trajectory view should reveal whether oscillations are dominated by threshold flicker (smoothing wins) or by genuine bus-state changes (memoryful scoring wins). The fix follows the data.

### Stop position along the route is the missing covariate

A prediction's expected confidence trajectory is **not the same shape at every stop**, and the scorer currently treats all stops uniformly. Two extreme cases on the same route:

- **The 66 at Navy Pier / Grand & McClurg** — within ~500 ft of the route's eastern terminal. A westbound bus appearing here has 99% of the route's variance still ahead of it; the upstream history of *this* trip is essentially the layover. The "DUE-but-far" check is also weird at terminals: the bus is *supposed* to be sitting near the stop with the engine off.
- **A 66 stop at Halsted or further west** — already absorbed 3+ miles of mid-route traffic, signal cycles, and dwell variance. The scorer has a long observation history to draw on, and the prediction's stability should reflect "we've already seen how this trip is running."

**Prior performance along the route is the right covariate.** Stops near the route's `pdist=0` have essentially no upstream signal, so the scorer should lean more on schedule + route-level priors and be tolerant of higher trajectory volatility. Stops at high `pdist` have a long upstream trace and should be intolerant of *new* state changes — if the bus has been confidently tracked for 4 miles, a single stale GPS sample two stops before the user's stop shouldn't drag the score back to `lowConfidence`.

Concretely, what the telemetry should capture and what the eventual scorer should consume:

- **Sample payload extension.** Record `stop_pdist_fraction` (the stop's `pdist` divided by the pattern's `lengthFeet`) on every `BusReliabilityScoreSample` row, alongside the absolute `stop_pdist_feet`. Cheap — both are already in `BusPattern` / `BusPatternGeometry`.
- **Per-stop trajectory aggregates.** Once we have ~weeks of samples per stop, compute the distribution of (`score_min`, `score_max`, `score_swing`, `transition_count`) for predictions confirmed at that stop. That's the empirical prior for "how volatile should the trajectory look here." Bin by `(route, stopId, hourOfWeek)` — same dimensions as the existing residual quantile bins so the two can compose.
- **Distinct from residual calibration.** Phase 4's `BusResidualQuantileBin` captures *how wrong* CTA's prediction was on average. The trajectory aggregates capture *how stable* our confidence in the prediction was over its lifetime. A stop can be low-residual but high-volatility (CTA gets the time right but our scorer flip-flops about whether to trust it) or vice versa. Both are useful; neither subsumes the other.
- **Connection to position along route.** At first cut, the simplest model: `expected_trajectory_volatility ∝ (1 - stop_pdist_fraction)` — terminals are noisy, downstream stops are calmer. Refine with empirical data once it exists. This becomes a prior that the scorer multiplies into the freshness/staleness penalties, so a 120 s GPS gap at McClurg costs less confidence than the same gap at a downstream stop where the trip's been observed for miles.
- **Pulls the scorer toward "use route history."** Today's scorer treats each refresh as independent. With per-(route, stop) trajectory priors plus memoryful per-prediction state (above), the scorer can answer "is this prediction behaving like other predictions at this stop have behaved?" rather than just "what do the current signals say in isolation."

This composes with the threshold-smoothing / memoryful-scoring fixes above: those handle *within-prediction* noise, this handles *between-stop* expectations. Both stories want the same logger as a starting point — `stop_pdist_fraction` is just one more column on the same sample row.

## Connection to existing pieces

- **[CONFIDENCE_INTERVALS.md](docs/CONFIDENCE_INTERVALS.md)** — bus prediction CI is one of the named intervals this work is judged against. Phase 4's residual quantiles *are* the per-bus version of the prediction CI. The reliability scorer is what keeps that CI honest: when evidence is weak, abstain rather than emit a confident wrong number.
- **[SYNTHETIC_ROUTES.md](docs/SYNTHETIC_ROUTES.md)** — same data shape (per-corridor residual histograms). When the peer observer eventually publishes per-bin priors, the on-device calibrator consumes them as a base prior and personalizes from there.
- **[DOOR_TO_DOOR.md](docs/DOOR_TO_DOOR.md)** — bus legs need a wait-time distribution and an in-vehicle-time distribution. Phase 4's quantile bins are the wait-time distribution input for door-to-door composition. The reliability scorer's abstain signal also tells the trip planner not to count a sketchy bus arrival as a viable leg.
- **[`ArrivalBiasStore`](Packages/TransitCore/Sources/TransitDomain/ArrivalBiasStore.swift) / [`ArrivalGrader`](CozyFox/Learning/ArrivalGrader.swift)** — already doing per-(route, direction, stop) bias accumulation for trains and buses. Phase 4 extends with the horizon and hour-of-week dimensions and the quantile bins. The grader's confirmation logic is the seed for "confirmed arrival" until phase 3's pattern crossings are available.
- **[`feedback_cozyfox_invisible_predictions`](feedback_cozyfox_invisible_predictions.md)** — non-negotiable. Reliability state changes ranking, styling, and whether a row appears; it never produces words. The Python prototype's `rider_message` field is exactly the surface this rule forbids.
