# Synthetic route corpus + prediction model spec

> Status: idea capture, updated 2026-05-16. Sister doc to `DOOR_TO_DOOR.md` (composition) and to whatever-the-other-agent is building (the predictor itself). This doc specifies what the model needs to predict, what features it needs, what data we collect to train and grade it, and what "correct" looks like.

## The idea

For the user to get good estimates anywhere in the city, we want a model that produces *probabilistic, real-time-conditioned, decomposable* travel-time predictions. The way to train and grade such a model without waiting for real user trips is to issue **synthetic prediction queries** across canonical Chicago corridors continuously, and grade them retrospectively against the recorded real-time feed stream. The continuously-growing log of `(features, prediction, retrospective truth)` is the **corpus**.

Two artifacts, related but separate:

- **The model.** Predicts a probabilistic door-to-door travel time given `(origin, destination, start_time, current system state)`. Built by another agent in another project. Lives where it lives.
- **The corpus.** A background service on the user's machine that issues synthetic queries on canonical corridors, records upstream feeds, and persists `(features, prediction, retrospective truth)` rows. Owns the data side; consumes the model as a black box.

This doc is the **contract between them** — what the model needs to output, what features it gets to consume, and what the corpus is guaranteed to record.

For now: corpus runs on the laptop, exposes a CLI, user pokes destinations at it and sees what comes back. Where the model runs (laptop, home box, eventually the phone) is a separate question.

## What the model predicts

Output is a distribution, not a point estimate.

Per query `(origin, destination, start_time, mode_choice?)`:

- **Total** travel-time distribution: at minimum `(p20, p50, p80)`; ideally Monte Carlo samples so we can composite further downstream.
- **Per-leg breakdown**: each leg gets the same distribution shape. Legs are typed: `walk`, `wait`, `vehicle (train|bus|metra|intercampus)`, `bike (classic|ebike)`, `transfer`.
- **Confidence on the distribution itself**: how much corpus support is behind this estimate. Wide-and-confident is different from wide-because-we-don't-know.
- **Mode recommendation** when `mode_choice` is unpinned, with the per-mode distributions exposed so the caller can apply its own policy (fastest-mean vs. lowest-p80 vs. catching-probability).
- **Failure-aware outputs** for legs that can fail with recovery cost (classic Divvy with dock-full at destination — see DOOR_TO_DOOR's decision math). The leg's distribution conditions on success; an explicit `p_fail` and `recovery_cost_distribution` come alongside.

Why distributional:
- Catching probability on multi-leg trips needs tails (DOOR_TO_DOOR).
- The fast-but-risky vs. reliable-baseline decision needs `p_fail`, `R`, and `M` per the same doc.
- The confidence band drives UI behavior (BigNumber when tight, range when wide).
- Calibration only means something against a distribution.

## What we want from the model

Beyond just "produce a number":

- **Conditional on current real-time state.** "Red Line is currently 15% slow" must move the prediction *now*, not after a week of evidence accumulates in a bias store. This is the entire point of doing the work; if the model can't condition on the live feed, schedule-plus-bias already does the job.
- **Decomposable.** We can introspect which leg drives the spread, and which feature drives the leg. Black-box end-to-end is harder to debug when the prediction is wrong.
- **Online-updatable.** New observations refit the posterior without a full retrain. The corpus produces several hundred training rows per hour — the model should absorb them.
- **Calibrated tails.** Predicted p80 = observed p80 across the corpus, ±10%. Untrustworthy tails make the catching-probability work in DOOR_TO_DOOR meaningless.
- **Honest "no data" output.** When the corpus has nothing useful (cold corridor, weird hour), the model returns wide-and-low-confidence rather than confidently extrapolating. The `confidence` field is the contract.
- **Directional + temporal asymmetry from features.** Same OD, opposite hour, very different distributions (DOOR_TO_DOOR's worked example proves this is structural). The model should *learn* this from features, not need hand-coded "rush-hour" rules.
- **Compose-able legs.** Per-leg distributions can be sampled from independently to get total-trip distribution. We assume independence at MVP and revisit when the corpus has data to measure correlation.

## Features (input spec)

Roughly in order of expected signal strength. Tier 1 must be wired before the model is worth grading; tiers 2–3 are refinement passes.

### Tier 1 — high signal, must have

**Context** (apply to every leg of every query):
- Time of day, circular-encoded (sin/cos of seconds-since-midnight).
- Day of week, categorical.
- `is_holiday`, `is_school_day` flags from a curated calendar.
- Active alerts on each leg (closures, single-tracking, slow zones). Boolean per known alert type plus a free-text embedding optionally.

**Per train/bus leg:**
- **Current vehicle position** on the line at query time, encoded as `(position_along_route, eta_to_each_remaining_stop, snapshot_age_seconds)`. The single biggest variance reducer over schedule.
- **Recent run-time observations** — distribution over the last 60 min for this `(line, stop_pair)`. Captures the operational mood without needing weather features explicitly.
- **Headway irregularity** — observed headway over the last hour vs. scheduled headway. Bunching is a major source of wait-time variance.
- **Time until next departure** at the boarding stop, with confidence (the tracker's own ETA has known biases).

**Per Divvy leg** (consume the other agent's bike model rather than reimplement):
- Pickup-station **usable bike count distribution** at arrival time at the dock, not current count. Listed-vs-rideable gap baked in (DOOR_TO_DOOR has the why — e-bike disability + pulse drains mean mean count is the wrong summary).
- Dropoff-station **dock availability distribution** at arrival time.
- Free-bike-park eligibility at destination (boolean from geofence + station type).
- Corridor-specific ride duration distribution (the bike model owns this).

**Per walk leg:**
- Distance (meters along walking graph, not crow-fly).
- Personal pace if available (on-device); generic 1.3 m/s prior otherwise.

**Per transfer:**
- Scheduled vs. observed headway of the connecting service.
- Walking distance / time between platforms or stops.
- Real-time next-vehicle ETA at the transfer point (at the predicted arrival moment of leg 1).

### Tier 2 — useful, second pass

- **Weather:** temperature, precipitation, wind speed/direction. Affects walk pace, bike usability (wind affects classic more than e-bike), bus dwell in extreme conditions.
- **Special-event flags:** Cubs/Sox/Bears/Bulls/Blackhawks game; festivals; parades. From a curated calendar.
- **Long-run historical prior** for `(line, stop_pair, hour, dow)` — the base distribution the real-time signal updates against. Computed from accumulated corpus data once enough has accrued.
- **Mode-specific catalog data:** station type (key vs. minor — affects dwell), platform position relative to exit, transfer geometry, fare-gate location.

### Tier 3 — refinement, later

- **Per-user features:** personal walk pace by time of day, personal station-entry preferences, personal transfer pace.
- **Bike refinement:** wind direction-of-travel alignment, rider-specific bike speed (from on-device history).
- **Sidewalk / hill profile** on walk legs.
- **Crowding** at boarding (currently no signal for this — would need to come from someone).
- **Train-specific:** car-count, run number (some runs are systematically slower).

## Data we collect (corpus contract)

Five tables, persisted continuously. Schema sketches — types are intentionally loose, the point is what gets stored.

### 1. `feed_snapshots` — the raw upstream stream

| Field | Type | Notes |
|---|---|---|
| snapshot_id | UUID | |
| ts | timestamp | UTC |
| feed | enum | `cta_train`, `cta_bus`, `metra_rt`, `divvy_gbfs`, `cta_alerts`, `intercampus`, `weather` |
| payload | blob | gzipped raw response |
| corridors_covered | int[] | for replay indexing |

Cadence 60–90s per feed. Compressed; estimate ~2–5 GB/month total. This is the load-bearing table — without it, retrospective grading is impossible.

### 2. `synthetic_predictions` — one row per (corridor × cadence-tick)

| Field | Type | Notes |
|---|---|---|
| prediction_id | UUID | |
| ts | timestamp | when the prediction was issued |
| corridor_id | string | FK to `corridors` |
| start_origin | (lat, lon) | |
| start_destination | (lat, lon) | |
| predicted_total | JSON | `{p20, p50, p80}` or sample array |
| predicted_legs | JSON | array of `{mode, line, from, to, dist, p_fail?, recovery?}` |
| feature_vector | JSON | feature snapshot at prediction time — verbatim, so backtests are reproducible |
| predictor_version | string | hash of model + config |
| confidence | float | model's own estimate of how much it knows |

### 3. `retrospective_truths` — filled in once a prediction's window has passed

| Field | Type | Notes |
|---|---|---|
| prediction_id | UUID | FK |
| ts_settled | timestamp | when grading completed |
| actual_total_min | float | reconstructed from snapshots |
| actual_legs | JSON | per-leg actuals |
| truth_confidence | float | how cleanly the snapshots bracket each leg — mid-leg sampling is messier than bracketing |
| error_total | float | actual − predicted_p50 |
| error_legs | JSON | per-leg errors |
| within_p20_p80 | bool | for calibration tracking |

### 4. `corridors` — the seed set

| Field | Type | Notes |
|---|---|---|
| corridor_id | string | |
| origin | (lat, lon, label) | |
| destination | (lat, lon, label) | |
| direction | enum | `outbound`/`inbound` — *always* two rows per OD pair, never collapse |
| seed_modes | enum[] | which modes the corridor exercises |
| priority | int | for poll-budget allocation |

### 5. `user_trips` (optional, later) — real user trips as gold ground truth

Same shape as `retrospective_truths` but sourced from on-device trip logs rather than reconstruction. Higher trust, much sparser.

## "Synthetic queries" — what makes this tractable

Subtle but load-bearing: we are not simulating user behavior. We issue prediction queries against the real-time stream and grade them retrospectively.

At 7:00 AM the service asks "what would a Loop → Davis Metra trip take, starting now?" — predictor returns 47 min. By 7:50 AM, the recorded snapshots show the Brown Line train the synthetic rider would have caught arrived at Davis at 7:46; walks bracket it; retrospective truth is ~46 min. Prediction error: +1 min. The "rider" never existed. The trains, buses, bikes, and walks are all real-world signals replayed against the predicted journey.

This is the same shape divvy-observer already uses to grade dock predictions — no rider needed to know what the dock state was.

The consequence for build order: **the corpus has to be a real-time recorder first, a predictor harness second.** Without persisted feed snapshots, no retrospective grading is possible. Phase 0 is mostly a logger, even though that's the least exciting part.

## Why this lowers variance for the user

Schedule-only predictions get the average of the system; the on-device bias store ([ArrivalBiasReader](Packages/TransitCore/Sources/TransitDomain/ArrivalBiasReader.swift), [LocalPredictionEngine](Packages/TransitCore/Sources/TransitDomain/LocalPredictionEngine.swift)) corrects from the user's own trips, which are sparse. A model conditioned on the corpus has different leverage:

- **Cold corridors** — routes the user has never taken. Bias store has nothing; corpus has fresh observations.
- **Transient perturbations** — slow zones, weekend single-tracking, weather, special events. Bias store learns over days; corpus updates in hours.
- **Whole-system conditioning** — when the Red Line is broadly slow today, *every* prediction that touches the Red Line moves, not just the ones for stop-pairs the user has ridden.

What this *doesn't* replace: per-user pace, personal station preferences. Those stay on device and compose with the corpus prior.

## How the corpus serves the model

Three relationships, in order of importance:

1. **Grading.** `(predicted, actual)` pairs flow into accuracy/calibration metrics. This is the testing harness; everything else is downstream.
2. **Training data.** Each `(feature_vector, retrospective_truth)` row is one training example. Continuous, no waiting for users.
3. **Inference enrichment.** At query time, for the corridor matching the user's request, the corpus exposes "the last 20 completed trips had this distribution." Even the simplest possible model — "return that distribution" — beats schedule-only when corridor matches are fresh.

The corpus is the **data side**. The model is the **estimation side**. The contract between them is the schemas above plus the `predictor_version` field, which lets multiple model versions run in parallel against the same stream for A/B.

## What to seed (corridors)

Order by personal load-bearing-ness, not by coverage:

1. **Evanston ↔ Loop**, both directions, via Davis Metra and via Central Metra. DOOR_TO_DOOR's worked example; the directional asymmetry (Benson & Church p(dock full) ≈ 0.45 at 7 AM, University Library 100% full 3–7 PM) is exactly what the corpus should learn to surface.
2. **Northwestern Intercampus** endpoints, both directions. Fully deterministic schedule — clean calibration target.
3. **CozyFox-pinned destinations** ↔ Home, both directions.
4. **Spanning corridors** for geographic spread — one Blue Line, one Pink Line, one south-side Red Line, one west-side bus-heavy corridor. Existence is so corridor-matching has interpolation targets even for unfamiliar destinations.

MVP target: ~10 corridors × 2 directions × 5 min cadence ≈ 240 predictions/hour. Fits inside CTA Train Tracker rate limits if the recorder batches polls across corridors sharing a line.

## Corridor matching (query → corpus)

Once a user asks `A → B`, which corridor's observations inform the answer?

1. **Endpoint-snap.** Map A and B to nearest transit stops; find corridors that share both stops (or one shared stop + short walk on each end). Cheap, debuggable, fails loudly. MVP choice.
2. **Path overlap.** Score corridors by Jaccard overlap of stop sequences. Better for partial matches.
3. **Kernel / GP regression** over `(origin_xy, dest_xy, hour, dow)` features. Handles "no exact match" gracefully; risks confident-looking answers far from any corridor.
4. **Hybrid.** Snap when a strong match exists; GP for residual.

Start with (1). The `freshness` field in the API response makes the failure mode visible: "only matching corridor was evaluated 4h ago" is actionable. (3) is phase 3+, not MVP.

## Where compute lives

Less load-bearing once we're framing this as model-spec — but the corpus still has to run somewhere.

- **Laptop.** Works until it sleeps. Fine for personal exploration.
- **Home always-on box** (Mac Mini, Pi, NAS). Natural target. Phone reaches it on Wi-Fi or Tailscale; falls back to a recently-synced corpus snapshot when away.
- **Cheap VPS.** Always reachable but adds a public surface; data leaves the user's machines.
- **Phone.** Can host a recently-synced slice for offline estimates; won't run the background load.

CozyFox's "no backend" discipline (`CLAUDE.md`) is preserved if the home box is **part of the user's own infrastructure**, not a backend. Phone treats it as cache, corpus as enrichment, the direct-to-provider path still works if the box is unreachable.

The model itself can live in the same place or somewhere else — the contract is just the schemas. The other agent gets to pick.

## Testing-harness aspect

The framing the user led with, and the place this earns its keep:

- **Continuous prediction A/B.** Two `predictor_version` rows in the same `synthetic_predictions` table, scored against the same `retrospective_truths`. Per-corridor, per-hour, per-mode error distributions, compared in hours not weeks.
- **Regression detection.** A code change that worsens accuracy shows up within a day. Wire a daily summary into the workflow and bad model changes get caught before they ship.
- **Bias surface mapping.** Which `(corridor, hour, mode)` cells are systematically over- or under-predicted? The corpus is the input for a city-wide bias correction layer, analogous to what `ArrivalBiasReader` does per-user but without needing the user to have ridden.
- **Counterfactual replay.** Re-run a new predictor over historical `feed_snapshots`, compare to original `retrospective_truths`. Iterating on the model becomes an afternoon task instead of a "wait two weeks for live data" task. This is probably the biggest single accelerator.

If we shipped only the harness and never the user-facing feature, the model would still get measurably better. That's the order of priorities.

## Acceptance criteria — what "correct version" looks like

Concrete targets for the model, measured against the corpus:

- **Per-corridor median absolute error < 90s** on completed predictions in typical-conditions windows (weekday daytime, no active alerts), once 2+ weeks of corpus data exists.
- **Tail calibration:** observed p80 ≈ predicted p80 ± 10%, measured weekly per corridor (collapsed across corridors when sample size is sparse).
- **Real-time conditioning works:** on alert-days (slow zones, single-tracking), residual MAE ≤ 1.5× alert-free MAE. If alert-days look just like alert-free days in the error distribution, the model isn't actually consuming the alert feature.
- **Cold-corridor reasonable:** when corridor-matching falls back to a non-exact match, MAE bounded at ≤ 2× the typical-conditions MAE, and `confidence` is reported as low.
- **Failure-aware Divvy:** classic-Divvy legs to docks with historical p(dock full) > 0.3 must include `p_fail` and `recovery_cost` outputs, and the recovery distribution must be calibrated separately (it's a different beast from the success distribution).
- **Truth-confidence honest:** the `truth_confidence` distribution in `retrospective_truths` is meaningful — low-confidence truths are excluded from headline accuracy metrics.

These are the numbers; the look-and-feel acceptance ("does it actually help me make a train") is a separate gate the user runs on the CLI before any CozyFox integration.

## On-device deployment

The endgame: every CozyFox install carries a compact predictor on-board plus a small snapshot of corridor priors, and can answer any `(origin, destination, start_time)` query locally — no home-box reachability required, no per-user data leaving the device. The home box (if the user runs one) becomes an enrichment that ships fresher priors, not a dependency.

### What ships in the app

Three artifacts. The first two are bundled at app-release cadence; the third refreshes daily over the wire.

1. **The predictor** — Core ML model (`.mlpackage`), trained against the corpus and converted via [coremltools](https://github.com/apple/coremltools). Input: per-leg feature vector. Output: distribution params (`p20, p50, p80`) per leg, plus `p_fail` / `recovery_cost` for legs that can hard-fail.
2. **Baseline corridor priors** — compact lookup of recent observed distributions for the seed corridors, indexed by `(corridor_id, hour_of_week)`. Used as a strong prior when the user's query matches a known corridor. Snapshot taken at app-build time so the app is useful before any network refresh.
3. **Daily priors refresh** — small payload downloaded over Wi-Fi from a static URL (or from the user's home box, if reachable). Recent run-time distributions per `(line, stop_pair, hour)`, recent headway irregularity per line, current alert-state aggregates. Lets the on-device model respond to system-wide perturbations between app updates.

### Recommended model architecture

The corpus features are tabular and per-leg. Two architectures fit cleanly on-device:

- **Quantile gradient boosting** (LightGBM with quantile loss, multi-quantile via a single model with three outputs). Tabular ML's strongest baseline; small after conversion; trains in minutes; well-supported by `coremltools`. **Recommended start.**
- **Small MLP**, 2–3 layers × 32–64 units, multi-output head (one neuron per quantile). More flexible if cross-feature interactions get gnarly; trains in PyTorch; slightly bigger.

What probably doesn't ship to phones:
- **Gaussian Processes** — tail calibration is beautiful, but cubic training cost and awkward serialization make them a phone-deploy nonstarter. Use them centrally if helpful, distill to a small model for the phone.
- **Large transformers / LSTMs** — overkill for ~30 features per query, and the latency/size cost isn't justified by the accuracy gain on this shape of problem.

The right move for a future "we want the rich model on the phone" is **knowledge distillation**: train a big model centrally with every feature you can think of (weather, special events, long-horizon history), then train the small on-device model to mimic its outputs on a held-out feature subset. The on-device model gets accuracy it couldn't achieve from its own feature set directly.

### Compression strategies, in order of bang-per-buck

1. **Weight quantization to int8.** ~4× smaller model, typically < 1% accuracy loss. Core ML supports natively. Do this first.
2. **Single model, multi-output head.** Train one model to produce all three quantiles simultaneously rather than three separate models. ~3× smaller than three models; comparable accuracy.
3. **Columnar priors with dictionary encoding.** Store the corridor-priors lookup as Parquet-style columns with categorical fields dictionary-encoded. Per-corridor-per-hour-of-week distribution is ~24 bytes raw; 20 corridors × 168 hour-of-week buckets ≈ 80 KB raw, well under 20 KB after encoding.
4. **Pruning.** Zero out small weights, sparsify. Diminishing returns past ~50% sparsity; usually not worth it on already-small models.
5. **Distillation** as discussed above — the big-model-on-server, small-model-on-phone pattern. Add when 1–3 plateau.

Realistic bundle budget: **predictor < 500 KB, baseline corridor priors < 50 KB, daily-refresh payload < 20 KB.** Roughly the size of one mid-resolution PNG icon. Easy budget for an iOS app.

### On-device inference path

Query: `A → B` starting at `T`.

1. Snap `A` and `B` to nearest stops via existing CozyFox resolvers (`NearestStationResolver`, `NearestBusStopResolver`, `NearestBikeResolver`).
2. Enumerate candidate routes via existing planners (`TripPlanner`, `CommutePlanner`).
3. For each leg, assemble the feature vector:
    - **Live app state** — current vehicle positions (already fetched by `RefreshCoordinator`), active alerts, scheduled headway from bundled catalogs.
    - **Daily-refresh payload** — recent run-time distribution for `(line, stop_pair, hour)`, recent headway irregularity, current alert-state aggregates.
    - **On-device** — personal walk pace (from `PersonalAccessEstimator`), time-of-day, dow, holiday flag.
4. Run the predictor per leg → distribution params (+ `p_fail` / recovery for failure-prone legs).
5. **Compose legs** in Swift — Monte Carlo sampling or moment-matching. `PortfolioEvaluator` is the natural home.
6. **Blend with corridor prior** when the candidate route closely matches a known corridor in the priors snapshot, weighted by freshness.
7. **Blend with per-user bias** from [ArrivalBiasReader](Packages/TransitCore/Sources/TransitDomain/ArrivalBiasReader.swift) — corpus output = city-wide Bayesian prior, per-user trips = likelihood.

Expected end-to-end latency: well under 50 ms for multi-leg trips. Battery: negligible (Core ML on Apple Silicon is essentially free at this scale). Composition logic in Swift dominates, not the model call.

### iOS pipeline

Training side (Python, wherever the model lives):
- Train in LightGBM or PyTorch.
- Export to `.mlpackage` via `coremltools`. Pin the conversion target to iOS 17+ to get the newer ops.
- Validate the converted model against the original by running both on a held-out slice — Core ML conversion is mostly faithful but not always perfect; this catches regressions.

Bundle side (Swift / Xcode):
- New SPM library at `Packages/TransitCore/Sources/TransitPredictor/` (peer to `TransitDomain`). Owns the `.mlpackage` and the priors snapshot.
- `CorpusPredictor` actor wraps the `MLModel` instance and exposes a Swift API: `predict(leg:features:) async -> LegDistribution`.
- Existing planners and learning stores call into it.

Updates side:
- Predictor model: redeployed via app updates (monthly cadence?). Stable.
- Baseline priors: redeployed via app updates.
- Daily refresh: small JSON or Protobuf payload over HTTPS. The corpus service writes once a day to a static URL (cheap S3-style hosting, signed for integrity if we care). Phone fetches in the background, falls back to whatever it already has if unreachable.

### What this gets the user

- **Works offline.** Phone predicts whether or not the home box is reachable, whether or not the user has Wi-Fi at query time. Last-known refresh is the floor.
- **No per-user data leaves the phone.** The predictor and priors are public; per-user features (walk pace, station preferences, trip history) stay on device. Per-user composition happens after the on-device predictor returns.
- **Sub-second predictions** with no round-trip.
- **Survives the user not running a home box.** Bundled snapshot + daily refresh from a static URL is the floor. Home box becomes an enrichment for users who want fresher priors.
- **Same model everyone gets.** The predictor doesn't depend on the user — only the composition layer does. Easier to test, easier to A/B between releases, easier to roll back if a release regresses accuracy.

## Open questions

**Model side:**

- **Per-leg vs. end-to-end architecture.** Per-leg is interpretable and composable; end-to-end might capture cross-leg correlation (Red Line slow → feeder bus also slow). Lean per-leg for MVP, revisit when corpus has the data to measure the correlation cost.
- **Independence between legs.** Simplest composition: sum means, add variances. Wrong but tractable. The corpus eventually tells us how wrong.
- **How is the bike model integrated.** Does it return same-shape per-leg distributions, or richer outputs (`p_fail`, recovery cost)? Probably richer — the DOOR_TO_DOOR decision math needs that structure. Spec the contract before the bike model commits to outputs the rest of the model can't consume.
- **Real-time staleness.** Snapshots are 60–90s old at query time. Decay-weight them, learn to predict the gap, or just treat as instantaneous? Probably instantaneous works for legs > 5 min; needs care for very short legs.
- **Calibration cadence.** Re-fit per-corridor calibration weekly? Daily? Global vs. per-corridor weights?
- **Long-run priors.** When the corpus has 3 months of data, do we precompute a `(line, stop_pair, hour, dow)` distribution and use it as a strong prior in low-data conditions? Probably yes — it's the cheapest "no real-time match" fallback.

**Corpus side:**

- **CTA rate limits.** Naive polling will blow the limit. Recorder needs to batch across corridors sharing a line. Measure steady-state QPS before turning the runner up to full cadence.
- **Truth confidence.** Mid-leg snapshots are messier than bracketing ones. The grader needs to honestly flag confidence on the truth itself — and the headline accuracy metrics should exclude low-confidence truths.
- **Cold start.** ~1 week of pure recording before retrospective grading produces enough rows to be useful.
- **Sparsity.** 20 corridors is not the whole city. Corridor matching has to fail gracefully — wide confidence band, not confident extrapolation.
- **Round-trip aliasing.** Always two corridors per OD pair (direction matters), never one bidirectional record.
- **Provider TOS.** Continuous polling at this cadence is roughly what an active app would do; one-time check that nothing in the upstream TOS forbids the logging.
- **Predictions stay invisible** (`feedback_cozyfox_invisible_predictions`). Corpus output shifts what the app shows and how wide the band is, never the words.

**Deployment side:**

- **Model update cadence.** Ship the `.mlpackage` inside the app binary (tied to App Store cadence, ~monthly), or background-download a fresh model at runtime (faster iteration, but adds an update path to secure and version)? Probably bundle for MVP, revisit when shipping cycles get painful.
- **Bundled vs. downloaded baseline priors.** Bundle freezes the snapshot at release; download-on-first-launch is fresher but requires the user to be online once. Probably bundle a 2-week-old snapshot + run a background refresh on first launch.
- **Feature-version compatibility.** A daily-refresh payload assumes a specific feature schema. If the phone has model v3 but the latest payload is for model v4, the phone has to gracefully fall back to its embedded baseline. Build a payload schema version into the protocol from day one.
- **Daily-refresh delivery.** Static HTTPS URL (S3-style, cheapest) vs. push-notification-triggered background fetch (timelier) vs. user's home box on local network (freshest). Start with static URL; the others are upgrades.
- **Privacy surface of the refresh fetch.** Even unauthenticated GETs reveal IP + that the device runs CozyFox. Probably fine for this app, but worth being deliberate — e.g., fetch over a VPN-friendly endpoint, no per-user tokens.
- **Distillation pipeline.** If/when the central model has features the phone can't easily compute (weather embeddings, special-event flags), set up a distillation pipeline so the on-device model can absorb the central model's accuracy without needing those features at inference time.

## Phases

**Phase 0 — recorder.** Persist `feed_snapshots` for ~10 corridors at 60–90s. Define and freeze `corridors` schema. ~1 week of soak. *Weekend of code + a week of waiting.*

**Phase 1 — synthetic runner + grader.** Issue predictions (whatever the model returns, even if it's a stub) every 5 min, grade against the snapshot stream once the window closes. Populate `synthetic_predictions` + `retrospective_truths`. `transit-corpus query <corridor>` shows the last 24h of predicted/actual. *Weekend.*

**Phase 2 — estimate API + CLI.** Endpoint-snap matching, tiny HTTP server, CLI. **First milestone the user pokes destinations at.** *Weekend.*

**Phase 3 — model integration.** Replace the stub predictor with the other agent's real model. Wire in `predictor_version` so multiple versions can run in parallel. Per-corridor error dashboards.

**Phase 4 — testing-harness output.** Calibration tracking, A/B comparison, counterfactual-replay tooling, daily summary.

**Phase 5 — on-device deployment.** The CozyFox integration phase, broken out because the work has shape:

- **5a — pipeline shakedown.** Bundle a stub Core ML model that just looks up the corridor prior for known corridors and returns the long-run distribution otherwise. Validates the entire chain (training → coremltools → bundle → Swift API → composition) before there's a real model to risk. Establishes bundle-size baseline.
- **5b — trained predictor.** Replace the stub with the actual trained model. Same I/O contract. Measure on-device accuracy against the corpus's `retrospective_truths` (CLI-side); confirm conversion didn't regress accuracy meaningfully.
- **5c — daily refresh.** Wire up the priors refresh payload. Corpus service writes daily to a static URL; phone fetches in the background; falls back gracefully when unreachable.
- **5d — per-user composition.** Blend on-device bias store with the corpus prior. Close the loop where the user's actual trips re-prime the model's view of their corridors.
- **5e (optional) — home-box live path.** For users running a home box, expose live (not daily) priors over Tailscale / local Wi-Fi. Pure enrichment — the bundled + daily path stays the floor.

## Connection to existing pieces

- **`docs/DOOR_TO_DOOR.md`** — composition logic (legs, catching probability, exchangeable modes, fast-but-risky vs. reliable baseline, classic-Divvy decision math). The model needs to *support* this composition; the corpus needs to *measure* whether the composition is right. The Davis Metra ↔ NU corridor is the natural seed for both.
- **The other agent's prediction model** — upstream of this doc. This doc is the contract: what it predicts, what features it consumes, what counts as "correct."
- **`Packages/TransitCore/Sources/TransitDomain/`** — [ArrivalBiasReader](Packages/TransitCore/Sources/TransitDomain/ArrivalBiasReader.swift), [LocalPredictionEngine](Packages/TransitCore/Sources/TransitDomain/LocalPredictionEngine.swift), [PersonalAccessEstimator](Packages/TransitCore/Sources/TransitDomain/PersonalAccessEstimator.swift). Per-user, on-device. Compose with the corpus output: corpus = city-wide Bayesian prior, on-device = per-user likelihood.
- **`../divvy-observer/`** — already the data-collection and modeling project for Divvy. The bike-specific half of the model lives there or in the other agent's project; the corpus consumes those outputs through the same per-leg contract as every other mode.
- **`feedback_cozyfox_invisible_predictions`** — model output is a state-shaping input. Changes what's ranked, defaulted, and surfaced; never the words on screen.
