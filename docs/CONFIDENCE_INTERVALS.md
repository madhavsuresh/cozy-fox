# Guiding principle: shrink the confidence intervals

> Status: idea capture, 2026-05-16. Sister doc to `SYNTHETIC_ROUTES.md` (the corpus side) and `DOOR_TO_DOOR.md` (the composition math). This one names the north-star metric the whole system optimizes for, and decomposes it into the specific intervals we can actually instrument.

## The thesis

Everything the app, the learning machinery, and the peer observer projects (`../transit-observer/`, `../divvy-observer/`) do should be evaluated by **whether it tightens a specific confidence interval**. Features that don't reduce a CI are either (a) instrumentation, which is fine, or (b) noise. The bias toward shipping more *capabilities* should be replaced with a bias toward giving sharper, better-calibrated estimates on the capabilities we already have.

This sits underneath the existing "predictions stay invisible" principle. The CIs are not surfaced to users as numbers; they shape state (rank, defaults, prefetch, what tiles show) and they show up on a **debug surface** I look at as the sole user.

## The intervals we actually track

There are two distinct CIs. They get confused if you don't name them separately.

### 1. Route-surfacing CI — did we offer a route the user actually took

Metric: `P(taken_route ∈ surfaced_set)` where `surfaced_set` is everything the user could have seen on a glance (ranked alternatives, not just the top tile).

What it requires:
- **Trip logging**: every completed trip records (origin, destination, departure time, mode sequence, per-leg path). Boarding detection + region monitoring + commute leg tracker already produce most of this signal; we need to actually persist a "what they took" record per trip.
- **Surfaced-set snapshot at decision time**: when the user opens the app and we infer/commit a trip, we need to also snapshot the ranked alternatives we *would* have shown for that OD. Without this snapshot the metric is unmeasurable retroactively.

Failure mode we care about most: the user takes a route we didn't surface at all. That's the highest-priority signal in the system — it means we're missing a modality, a corridor, or a context (time-of-day, weather, alert state) that meaningfully changes the choice. When this happens:
1. Log the gap loudly on the debug surface.
2. Hand the OD + context to the synthetic-route corpus to probe — issue queries on that corridor for the next N days, see if our predictions catch up.
3. If after probing the model still ranks the user's actual choice low, that's a learning-rule problem, not a data problem.

Note that "did the user take the *top-ranked* route" is a much weaker signal and we should not optimize for it. Users have legitimate reasons (comfort, fare, knowing a bus driver) to pick a non-top route. The interval that matters is *did we surface it at all*.

### 2. Prediction CI — end-to-end and per-leg, against ground truth

The phone has **golden** data: at the end of a trip we know the actual door-to-door wall time *and* the per-leg wall times (entered station at X, boarded at Y, alighted at Z, arrived at destination at W). This is the kind of ground truth `transit-observer` has to synthesize from feeds; the app has it natively.

For each completed trip we compare:
- Predicted total distribution `(p20, p50, p80)` vs. observed total.
- Predicted per-leg distributions vs. observed per-leg wall times.
- Per-leg residuals attributed back to which leg drove the total miss.

Two sub-metrics, both matter:
- **Coverage** — `P(observed ≤ p80)`. Target: 80% ±10. Calibration is the contract; if coverage is wrong, every downstream catching-probability calculation is meaningless.
- **Sharpness** — width of the p20–p80 band. A wide interval that covers truth is *not* a win; it just means we know nothing. We want coverage to hold *while* the band tightens.

Slicing matters: corridor, mode, hour-of-day, day-of-week. A single global number averages over the cases where we're great (a one-leg Purple Line trip at 10am) and the cases where we're terrible (multi-modal, rainy, alert active) and hides both.

The per-leg attribution is what makes this debuggable. "Total was off by 9 minutes" is uninteresting; "the wait kernel under-predicted by 7 minutes on the bus leg because headway irregularity was high and we didn't condition on it" is actionable.

## The debug surface

Single user (me), so this is a debug screen, not a feature. It does not need to be polished, but it does need to exist — without it the CIs are claims about state we can't see.

Minimum useful version:

- **Trip log table** (one row per completed trip): timestamp, OD, taken mode sequence, surfaced set (in/out), predicted total `(p20, p50, p80)`, observed total, per-leg predicted vs. observed.
- **Rollups by corridor / mode / hour-of-day**: coverage rate, mean sharpness, count, last-N residuals. Highlight rows where coverage drifts off 80%, where sharpness is wide, or where the taken-but-not-surfaced count is non-zero.
- **Gap list**: routes the user took that weren't surfaced, with timestamps and current synthetic-probe status for that OD.

Where it lives in the app: a hidden settings screen, behind a long-press or a debug build flag. Not on the main glance. This is fine and intentional.

## Tying in the observers

The two peer repos exist precisely to widen the data base when the user's own trips don't cover enough buckets:

- **`../transit-observer/`** — CTA L wait + in-vehicle + composed coverage at scale, with bucketed (line, direction, hour) coverage targets. Also raw collection for bus, Metra, Intercampus. The corridor-inventory dashboard already exists and surfaces under-validated buckets.
- **`../divvy-observer/`** — bike availability + duration models, the Divvy leg input to the door-to-door composition.

What "tying in" should mean operationally:

1. **The app's debug surface reads, doesn't compute.** The observers compute coverage/sharpness on their corpora; the app's debug surface should show *its own* gold-trip metrics next to the observer's bucketed metrics for the same corridor. Two columns: "what the corpus says" and "what your actual trips say". Disagreements are diagnostic.
2. **Gaps in app coverage drive observer effort.** When the trip log has wide-sharpness or low-coverage corridors, the synthetic corpus should bias its query distribution toward those corridors. Mechanism: the app emits a "where are my CIs wide" report; the observer's query sampler weighs by that report. Not implemented; the contract should be a JSON file in a shared location.
3. **Gaps in observer coverage drive app effort.** Reverse direction: if the observer's corridor inventory shows a bucket with <5 samples/week and the user is about to travel that bucket, the app should know the prediction is data-poor and widen its own band (or fall back to schedule).
4. **Don't duplicate kernel implementations across processes.** Cozy Fox's Swift kernels are canonical (per `transit-observer`'s README). The Python port in `transit-observer` validates equivalence via golden-file tests. Same discipline should apply to anything new: write it in Swift, port for validation, never the inverse.

## What this means for the backlog

Concrete operating rules:

- Every feature proposal should answer **"which CI does this tighten, and by how much?"** A new tile, a new mode, a new ranker — name the interval. If the answer is "none, it's a UX nicety," that's fine, but flag it as such.
- **Instrumentation before features.** We can't reduce CIs we can't measure. The trip log + surfaced-set snapshot is prerequisite to almost everything else here.
- **Calibration before sharpness.** A miscalibrated tight band is worse than a calibrated wide one. Once coverage hits target, push sharpness.
- **Per-leg attribution before global tuning.** When totals miss, find the leg before changing the model.
- **Cold corridors widen, they don't lie.** When data is thin, the right output is wide-and-confident-about-being-wide, not confidently extrapolated. The `confidence` field in the model contract (see `SYNTHETIC_ROUTES.md`) is the mechanism.

## Open questions / next concrete steps

- **Trip log schema.** What gets persisted per completed trip, where (SwiftData on the app group), and how it's surfaced. The pieces (boarding detection, leg tracker, commute autopinner) exist; the unified record doesn't.
- **Surfaced-set snapshot.** Where in the refresh/render path do we capture "what would have been shown for this OD at this moment". `RefreshCoordinator` is the natural owner.
- **Gap report file.** A JSON the app writes (where CIs are widest) and the observers read. Path, schema, refresh cadence.
- **Debug surface entry point.** Probably a long-press on the version string in settings, or a `DEBUG`-only tab.
- **Per-leg ground truth definitions.** Boarding is detected; alighting and walk-segment boundaries are messier. Need to pin down what "the bus leg ended" means in terms of phone signals (GPS clustering + heading change + region exit?).

Parking the next two probably belongs in the prediction roadmap memory rather than here.
