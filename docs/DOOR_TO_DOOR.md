# Door-to-door multimodal prediction (exploration)

> Status: idea capture / TODO. Not a plan yet. Pulled out of conversation on 2026-05-15.

## Vision

Given an endpoint (saved place, dropped pin, well-known destination), give a full **door-to-door** time prediction across **all modes** — walk, CTA bus, CTA train, Metra, Divvy classic, Divvy e-bike. Surface the best option, the realistic spread, and the choice points.

The Divvy half of this leans on probabilistic models that already exist in the sibling repo at `../divvy-observer/` (dock availability, ride durations, mobility partitions, etc.). The Cozy Fox app should be able to consume them **locally** — no backend, no roundtrip — somehow. How exactly is part of the exploration.

## Why this is the interesting problem

Per-mode arrival times we already have. The hard part is:

1. **Composing legs** with realistic uncertainty (not just summing means).
2. **Exchangeable legs**: at most choice points the rider has two or three modes that are roughly comparable; the answer is "the better of these" with the tail risk of each.
3. **Final-mile**: transit drops you somewhere, not at the door. Walk vs. e-Divvy vs. free-bike-park at destination is itself a sub-decision.

## Core idea: exchangeable legs

A *leg* is a segment of the journey with a defined start and end. An *exchangeable leg* is one where multiple modes can fill the same slot. Examples:

- "Northbound from here to Belmont" → bus OR Divvy OR walk-then-Red-Line.
- "Last 0.8 mi from the L stop to the door" → walk OR e-Divvy (if dock predicted open and reachable) OR a bike rack park.

For each candidate, predict `E[time]` and a tail (p80 / p90), then pick on a policy (fastest-mean, lowest-p80, etc.).

## Variables to model

### Bus / train leg
- [ ] Walk time from current position to the boarding stop.
- [ ] Wait time at stop given **my predicted arrival** vs. the bus/train's predicted arrival (not just the headline ETA — the joint distribution).
- [ ] In-vehicle travel time and its variance.
- [ ] Reliability of catching: probability the predicted vehicle is still there / is the one I get.

### Divvy (classic or e-bike) leg
- [ ] Time to find a *working* bike at the origin dock(s) — not all bikes are rentable; e-bikes especially churn.
- [ ] **Per-station, per-hour availability distribution** — not the current count, the predicted distribution at *trip-execution time*. divvy-observer's `station_status` rollups plus inferred-flow / station-community models are the input. Direction matters: the same station can be "fine" one half of the day and "always full" the other (see Evanston worked example below).
- [ ] **Listed vs rideable gap.** GBFS `num_bikes_available` / `num_ebikes_available` does *not* reflect lived experience. Two reasons:
    - Disabled or low-battery e-bikes can show up as available in feed but won't rent in the app. `num_bikes_disabled` catches some of these but not all (low-battery especially).
    - The *mean* count smooths over pulse-drain dynamics. At Sheridan & Noyes (NU) on a 30-day window, the morning mean is ~6 e-bikes, but **p(≤1 e-bike at any polled moment) ≈ 0.50**. Stations refill and drain in pulses; the lived "I keep finding nothing" matches the pulse minima, not the mean.
    - The right summary statistic for a rider is `P(usable bike at the moment I arrive)`, not the count distribution alone.
- [ ] **Classic vs e-bike separately.** Classic Divvy only works if a dock is predicted open at the destination — it has no free-park option, so dock failure means a hard re-route. E-bike can fall back to free-parking inside the geofence. See "Decision: classic Divvy when the destination dock might be full" below for the math.
- [ ] Ride duration over **this corridor specifically**, from my historical mobility data on that part of the city (the divvy-observer project already partitions the city into mobility tiles).
- [ ] Dock availability at destination at the moment I'd arrive — predicted, not current. divvy-observer has dock-state models.
- [ ] If destination dock is full / closed: distance to the **next** viable dock, and walk back.
- [ ] Free-bike parking: ignore docks entirely, leave bike anywhere — eligibility depends on the geofence rules and station type.

### Walking
- [ ] Distance and pace (personal pace, not generic — the prediction roadmap memory already has this on deck).

## Catching probability on multi-leg trips

For a multi-leg trip (e.g. bus → train transfer, or Divvy → train), the integrated time is **not** the sum of mean leg times. You can miss the second leg.

- [ ] Model `P(catch leg 2 | leg 1 finishes at time t)` as a function of leg-2 departure distribution.
- [ ] Marginalize over leg-1 finish time to get `E[total]` and the tail.
- [ ] Even single-leg trips have a catching component (the bus you "should" catch vs. the next one).

## Final mile

Same exchangeable-leg logic at the destination end:

- [ ] **Walk** from the last transit stop.
- [ ] **e-Divvy** if there's a dock within X meters of the destination and it's predicted open with bikes available at arrival time.
- [ ] **Free-bike park** at any rack near the destination — bypasses dock-availability uncertainty entirely, but only inside the geofence.

## Surfacing well-known destinations

- [ ] For places the user already cares about (Home, Work, saved destinations, top recent), keep a rolling door-to-door prediction ready — same way head-home today shows the next viable train.
- [ ] Compact view: "23m via Red Line" with a chip beneath that says "or 19m by e-Divvy if Wabash-Adams has a bike" — the option, not just the choice.
- [ ] Predictions stay invisible the same way the rest of the prediction layer is invisible (see `feedback_cozyfox_invisible_predictions` memory) — they shape what we *show* and *rank*, not the words on screen.

## Integration questions (the actual work)

How does the Cozy Fox app, which is Swift / iOS and has **no backend**, actually consume Python models that live in `../divvy-observer/`? Options to explore:

- [ ] **Export model artifacts** (ONNX / Core ML) and bundle them in the app or download from a static URL.
- [ ] **Periodic batch precompute**: divvy-observer writes out a small lookup table (per-tile ride duration distributions, per-dock availability curves) the app fetches and reads locally.
- [ ] **Local-only dev integration**: run divvy-observer as a local service for prototyping, then decide what to ship.
- [ ] Decide which models are worth shipping vs. which are research-only.

## Worked example: Evanston Metra ↔ campus

A specific real trip the door-to-door predictor should solve. Directionality and time-of-day both matter — the same corridor has very different failure modes depending on which direction and which hour.

### Morning: Metra (Davis St) → campus

Train arrives at Davis St Metra (Union Pacific North). Closest Divvy dock is **Benson Ave & Church St**, ~240 m from the platform — no dock is named "Davis." Options to reach a campus building:

- **E-Divvy** from Benson & Church → ride to a campus dock (University Library, Sheridan & Noyes, Chicago & Sheridan) → walk the last block.
- **Classic Divvy** from same dock — only viable if a dock is predicted open at the destination; classic has no free-park escape hatch.
- **Walk** the full distance.
- **Bus** along the corridor.

Failure modes the prediction layer needs to surface *before* leaving the platform:

- No e-bikes at Benson & Church by the time you walk to the dock. Mean is ~4 in the AM but the listed-vs-rideable gap above applies; ~1 disabled bike is typical so usable e-bikes is ~3.
- Destination dock full / closed at arrival → walk back from the next-closest dock.
- The naive campus target (University Library) is fine in the morning but **unusable as a dock-target in the afternoon** — direction and hour matter for the same station.
- The "load-bearing" alternative dock isn't free: Sheridan & Noyes (NU) is ~500 m / ~6 min walk north of central campus, so picking it as the campus dock adds walk time on the campus side.

### Afternoon: campus → Metra

This direction is where the station imbalance really bites, *and* there's a hard catching deadline at the Metra side. To catch a specific Metra departure:

- **Walk to a campus Divvy station, ride to Benson & Church (Davis Metra), dock there.** Two failure points: pickup and drop-off.
- **Walk the full distance** (fixed cost, no surprises).
- **Bus** along the corridor.

Failure modes:

- The closest campus dock might be empty of *usable* bikes — and the listed-vs-rideable gap is the operative thing, not the mean. The user reports Sheridan & Noyes is "constantly" without a bike despite a 30-day afternoon mean of 5–7 e-bikes. The afternoon hourly-mean data doesn't reproduce that experience, which is the point: the residual is some mix of (1) low-battery e-bikes that appear as available in GBFS but won't actually rent, (2) pulse-drain at class-out times the hourly mean smooths over, and (3) the user's specific commute minute catching the empty windows. The prediction layer needs to learn from *individual rental outcomes*, not just the smoothed feed.
- The obvious target (University Library) is **~100% full from 3 PM to 7 PM** — which means no bikes leaving, so it's a non-starter for pickup at the *exact* afternoon hours you'd want it.
- Even after a successful pickup, **docking at Benson & Church (Davis Metra) is the user's reported pain point**. The 30-day hourly mean understates it — afternoon p(dock full) sits low on average — but the dock *does* fill in pulses, especially when a southbound train is about to depart and other commuters are converging on the same dock. Lived experience > smoothed mean here, and the prediction layer should treat individual outcomes as evidence that updates the per-station, per-hour, per-departure model.
- The Metra departure is **fixed**, so the catching-probability term dominates here. Free-park inside the Divvy geofence (if eligible at that station) eliminates the docking risk entirely — that affordance might be worth surfacing explicitly when only classics are available. (See "Decision" below.)

### What `../divvy-observer/` already shows

30-day `station_status` window, key Evanston stations along the corridor. Numbers below show the mean count *and* the lived-experience-matching tail metric where it diverges:

| Station                                | 7–9 AM                                                              | 3–6 PM                                                                |
|----------------------------------------|---------------------------------------------------------------------|-----------------------------------------------------------------------|
| Benson & Church St (Davis Metra)       | ~4 e-bikes mean, **p(dock full) ≈ 0.45 at 7 AM** (drops to ~0 by 8 AM) | ~1–2 e-bikes mean, dock rarely full                                  |
| Central St Metra                       | ~4–5 e-bikes mean, p(dock full) ≈ 0.50                              | ~4 e-bikes mean, p(dock full) ≈ 0.60–0.90                            |
| Sheridan Rd & Noyes (NU)               | ~6 e-bikes mean **but p(≤1 e-bike) ≈ 0.50** — drains in pulses        | ~5–7 e-bikes mean, dock fine                                          |
| University Library (NU)                | ~2 e-bikes mean, p(dock full) ≈ 0.50                                | ~1–2 e-bikes mean, **p(dock full) ≈ 1.00** (3–7 PM)                  |
| Chicago Ave & Sheridan Rd              | ~2 e-bikes mean, dock fine                                          | drops to ~0 e-bikes by 5 PM, p(no e-bike) ≈ 0.87 at 5 PM             |

(Sparse hourly bins for a 30-day window, so the table is illustrative, not authoritative. Re-run the query for current values; see `../divvy-observer/data/divvy_readonly.duckdb` → `station_status`. Disabled-bike count is also in the schema and should reduce listed counts.)

Two lessons stick out and they're the whole reason the prediction layer earns its keep:

1. **The mean is the wrong summary.** "~6 e-bikes mean at Sheridan & Noyes morning" sounds great. But you arrive at a specific moment, and `p(≤1 e-bike) ≈ 0.50` says it's a coin flip whether you find anything. Use the distribution-at-arrival-time, not the count.
2. **Directional asymmetry is structural.** University Library is fine in the morning and unusable in the afternoon. Benson & Church is risky in the morning (dock full) and easier in the afternoon. Same station, opposite failure modes across the day. The user just learns "no bikes again" / "dock full again" mid-trip — the point of this work is to move that surprise to *before the leg starts*.

## Decision: classic Divvy when the destination dock might be full

The user's question, made concrete. You're at the campus side, classic-only at the source (no e-bikes left at Sheridan & Noyes), heading to Davis Metra (Benson & Church) for a fixed train. The dock at the Metra side is full a meaningful fraction of the time. Worth biking, or just walk?

Variables for the decision:

- `B` = time saved by biking vs walking, conditional on success.
- `P_dock` = probability the destination dock has space at arrival.
- `R` = recovery cost when the dock is full (ride to next dock + walk back to target).
- `M` = penalty for missing the Metra (next departure interval — UP-N at 30-min headways is typical off-peak, sometimes 10–15 min at peak, can be 60 min late at night).
- `P_miss(R)` = probability the recovery time pushes you past the Metra cutoff (depends on slack in the plan).

Expected loss vs walking the whole way (which is reliable):

```
E[loss] = -B + (1 − P_dock) × (R + P_miss(R) × M)
```

Plug in a realistic case — return trip toward the 5:40 PM Metra, classic bike, ~9 min ride vs ~17 min walk, dock-full probability roughly 0.4, +6 min if you have to bail to the next dock, 30 min until the next train, 50/50 you'd miss the Metra given the recovery hit:

```
E[loss] = -8 + 0.4 × (6 + 0.5 × 30)
       = -8 + 0.4 × 21
       = -8 + 8.4
       = +0.4 min
```

Roughly **a wash, with all the variance loaded on the downside**. A small overestimate of `P_dock` or `P_miss` and walking pulls ahead. Classic Divvy against a fixed Metra deadline at non-trivial dock-full probability is, on this back-of-envelope, **a losing or break-even bet** — the upside is the bike time savings (bounded), the downside is missing the train (large).

Three things change the answer:

- **E-bike available.** Free-park inside geofence eliminates the dock-full risk entirely; the calc flips to clearly worth-it.
- **Off-peak Metra with long headway.** `M` is the same, but `P_dock` at off-peak is usually higher and `P_miss` is lower because the train's still 30+ min away.
- **Big slack in the plan.** If you leave 20 min before the train rather than 12, `P_miss(R)` collapses; the only cost of dock-full is the recovery time, not the missed train.

UI takeaway — the user shouldn't see `p_dock = 0.55` or this formula. They should see:

- "Walk — 17 min, reliable" as the top option.
- A subtle "Classic Divvy not worth the risk to Davis right now" annotation if they hover, with the *why* available but not loud.
- And when the e-bike option lights up, it becomes the lead: "E-Divvy + free-park — 11 min" with confidence implied.

This is exactly the kind of decision the prediction layer should make silently, per the predictions-stay-invisible feedback memory.

## Generalizing: fast-but-risky vs reliable baseline

The classic-Divvy case is one instance of a shape that recurs throughout door-to-door planning. Worth naming, because once the prediction layer can handle this generally, a lot of choices collapse into the same machinery.

### Shape

Choose between:

- A **reliable baseline** at known cost `T_base` (walking is the canonical one).
- A **fast option** at cost `T_fast` that saves `B = T_base − T_fast` when it works, with probability `P_fail` of failing into a recovery action that costs `R` and may blow a downstream deadline with conditional miss probability `P_miss` and penalty `M`.

Expected loss vs baseline:

```
E[Δ] = −B  +  P_fail × (R + P_miss × M)
       └─┘    └──────┬───────┘ └─────┬─────┘
      upside     risk-weighted    downside
       (sure)     recovery cost   (catastrophic if M is big)
```

Fast option wins iff `B > P_fail × (R + P_miss × M)`.

### Where the same skeleton applies

Different problems in Cozy Fox's domain map onto exactly this template — only the variables change:

| Decision                                          | `B` (upside)               | `P_fail` (failure mode)              | Deadline?               |
|---------------------------------------------------|----------------------------|--------------------------------------|-------------------------|
| Classic Divvy vs walk to fixed Metra              | bike time saved             | dock full at destination              | Yes — Metra departure    |
| Tight transfer vs comfortable next train           | one headway saved           | miss the connection                   | Yes — the connection     |
| Race the closer L stop vs walk further to the next | shorter walk                | train arrives before you do           | Yes — train arrival      |
| E-Divvy final-mile vs walk from L                  | last-mile time saved        | dock empty / no usable bike           | Soft — meeting time      |
| Bus vs walk, no deadline                           | bus speed                   | bus delayed                           | No                      |
| Leave-now vs wait-for-next-Divvy-rebalance         | bike option opens up        | rebalance doesn't happen in time      | Whatever you're catching |

### Structural insight

**Bounded upside, potentially fat-tailed downside.** The upside `B` is capped by physics (a bike only saves so much vs walking). The downside is whatever `M` is — and `M` can be large (next Metra in 30 min, last train of the night, missing a meeting).

Two regimes:

- **No deadline (`M = 0`).** Collapses to ordinary expected-time minimization. `Fast wins iff B > P_fail × R`. This is where most mapping apps live and why they happily route you through risky shortcuts.
- **Hard deadline (`M` large).** `P_fail × P_miss × M` dominates. Even a low `P_fail` can sink the decision if `M` is big enough. The prediction layer must trade some expected-time gain for catching-probability — the user wants to *make the train*, not optimize the median.

### Implication for the prediction layer

- A leg-selection output isn't just an ETA — it's `(recommended action, P_success, fallback)`. The fallback is part of the recommendation, not an afterthought.
- Two policy modes corresponding to the regimes:
    - **No deadline:** minimize `E[T]`.
    - **Hard deadline:** ensure `P_catch ≥ θ` (e.g., 0.95) first, then minimize `E[T]` among options that clear the threshold.
- The risk tolerance `θ` is itself **learnable** from the user's accept/reject behavior on past recommendations — consistent safe choices → tighten `θ`, consistent close calls → loosen. (Same shape as the existing learning roadmap: behavior reveals preference.)
- **Multi-leg trips chain these decisions.** Leg-2's `P_miss` depends on leg-1's *actual* finish time, not its mean. So the right computation is over the joint distribution of leg outcomes, not the product of marginals. (Same point as the "Catching probability on multi-leg trips" section above — that section is one application of this general shape.)

## Open questions

- Which divvy-observer models are stable enough to consume? (`predictor.py`, `tile_predictor.py`, `dg_nissm.py`, `cdg_nmip.py`... need to triage.)
- How to keep the door-to-door spread **honest** without becoming overwhelming UI — one number plus tail, or a small distribution viz?
- Where does this live in the app — extend the head-home tile, or a new "trip" surface?
- Does this need a routing engine (OTP, Valhalla) for the multi-modal graph, or can we get away with per-corridor heuristics for now?

## Next deeper-exploration steps

1. Read through `../divvy-observer/src/divvy/{predictor,tile_predictor,dg_nissm,mobility_partitions,inventory_dp}.py` and write a one-page "what's available, what's stable" summary.
2. Use the **Davis St Metra (Benson & Church) ↔ campus (NU)** corridor as the first hand-constructed worked example, in both directions. The station imbalance is severe enough that the prediction is load-bearing (Benson & Church ~45% dock-full at 7 AM peak, Sheridan & Noyes drains to ≤1 e-bike ~50% of morning moments, University Library 100% full 3–7 PM). Build the door-to-door prediction end-to-end for one specific Metra departure and one specific class time, see what data is missing. The classic-Divvy decision math in the "Decision" section is the kind of output the predictor should land.
3. Decide the model-shipping question (ONNX bundle vs. precomputed lookup vs. local service).
