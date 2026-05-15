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
- [ ] Ride duration over **this corridor specifically**, from my historical mobility data on that part of the city (the divvy-observer project already partitions the city into mobility tiles).
- [ ] Dock availability at destination at the moment I'd arrive — predicted, not current. divvy-observer has dock-state models.
- [ ] If destination dock is full / closed: distance to the **next** viable dock, and walk back.
- [ ] Free-bike parking: ignore docks entirely, leave bike anywhere — eligibility depends on the geofence rules.

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

## Open questions

- Which divvy-observer models are stable enough to consume? (`predictor.py`, `tile_predictor.py`, `dg_nissm.py`, `cdg_nmip.py`... need to triage.)
- How to keep the door-to-door spread **honest** without becoming overwhelming UI — one number plus tail, or a small distribution viz?
- Where does this live in the app — extend the head-home tile, or a new "trip" surface?
- Does this need a routing engine (OTP, Valhalla) for the multi-modal graph, or can we get away with per-corridor heuristics for now?

## Next deeper-exploration steps

1. Read through `../divvy-observer/src/divvy/{predictor,tile_predictor,dg_nissm,mobility_partitions,inventory_dp}.py` and write a one-page "what's available, what's stable" summary.
2. Pick one well-known destination (Home is the obvious one) and hand-construct the door-to-door prediction end-to-end, including the exchangeable bus/Divvy choice, to see what data is missing.
3. Decide the model-shipping question (ONNX bundle vs. precomputed lookup vs. local service).
