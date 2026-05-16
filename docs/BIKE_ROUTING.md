# Bike routing / route quality for the Divvy leg

> Status: idea capture, 2026-05-16. Brainstorm only — no commitment, all options stay open. Sister to `DOOR_TO_DOOR.md` (composition math the bike leg has to fit into), `SYNTHETIC_ROUTES.md` (where bike predictions get graded), and `CONFIDENCE_INTERVALS.md` (the metric anything here gets judged against).

## The question

For door-to-door and exchangeable-route planning, the bike leg currently has dock + availability state (`DivvyGBFSClient`, `BikeRouteStore`, `BikeSpeedTracker`) but no notion of *which path through the city* a bike trip takes. The portfolio can rank "ride Divvy vs. take the Brown Line" but can't distinguish "Divvy via the Lakefront Trail" from "Divvy via Milwaukee Ave" from "Divvy via Damen at 8 AM, which is awful." This doc surveys what would be needed to make that distinction possible, and what's actually accessible to do it with.

The brainstorm started from two pointers the user surfaced: [CNT BikeChi](https://apps.cnt.org/bikechi/) and [Mellow Bike Map](https://mellowbikemap.com/).

## What's out there

### CNT BikeChi

A Mapbox PWA from the Center for Neighborhood Technology. Visualizes Chicago's bike infrastructure by type (protected / buffered / greenway / off-street / shared) plus tree-canopy overlay. Has a "cycling directions" UI button. **No public API.** The routing under the hood is Mapbox Directions with their cycling profile — accessible only if you re-pay Mapbox for it directly. The visible data layers are aggregated from CDOT, Cook & DuPage counties, and OSM cycle tagging — all of which are independently downloadable.

Takeaway: useful as a *reference rendering* of what "good bike infrastructure scoring" looks like; not a service Cozy Fox can call.

### Mellow Bike Map

Open source (MIT) at [jeancochrane/mellow-bike-map](https://github.com/jeancochrane/mellow-bike-map). Self-hosted Django + PostGIS + pgRouting stack. Edge-weighting preference order: off-street paths → "mellow" side streets → main streets with bike lanes → everything else. The "mellow" classification is hand-curated by Chicagoans who actually bike here and is stored as a fixture (`db/import/mellowroute.fixture`) — this is the load-bearing IP, since OSM + CDOT data is public but local-knowledge street-pleasantness isn't encoded anywhere else.

No documented public API at mellowbikemap.com — only the web UI. Self-hosting is documented (Docker compose) but is unambiguously "a backend."

Takeaway: the *methodology* and *curated tagging* are reusable; the *architecture* (server-side pgRouting) isn't a fit.

### Apple `MKDirections` with `.cycling`

Added in iOS 14, available without a key, runs on-device, returns polyline + ETA. Treats Chicago as Chicago — works, but uses Apple's own road graph and doesn't appear to preference CDOT bike infrastructure aggressively. No customization of edge weights. Free.

Takeaway: the only on-device routing option that doesn't require infrastructure. Quality is "good enough to start" but ignores everything we'd want it to know.

### Other routing engines worth naming

- **Mapbox Directions API** — best cycling routing in Chicago commercially (since CNT and many others use it). API key + per-request pricing. Off-device call → arguably violates no-backend, though `CTATrainClient` and friends are also off-device calls, so the line is at "provider with a TOS we're a normal client of" not "any HTTP."
- **Google Directions API** — same shape as Mapbox, comparable quality, similar cost.
- **OSRM / Valhalla / GraphHopper with a cycling profile** — open-source routing engines. Can be self-hosted, or compiled to a static graph. Theoretically embeddable on iOS but the work is enormous and the bundled graph would be hundreds of MB even for Chicagoland.
- **Cyclers Tech SDK** — commercial cycling/micromobility routing SDK that came up while searching; advertises on-device-capable. Worth a deeper look only if free options prove insufficient.

## The fork in the road: routing vs. scoring

The most important decision is *what kind of bike-awareness Cozy Fox actually needs*, because the answer determines which of the above is even relevant.

### Routing — "given start and end, generate a bike polyline"

You need a graph search engine that respects infrastructure preferences. Options:

1. `MKDirections.cycling` (free, on-device, Chicago-aware but doesn't prefer CDOT lanes).
2. Hosted third-party (Mapbox / Google) — paid, off-device, but high quality.
3. Self-hosted Mellow Bike Map or OSRM-cycling on a home box — preserves the "user's own infra" framing from `SYNTHETIC_ROUTES.md`, fits naturally if the home-box-for-corpus already exists.
4. On-device OSRM / OpenTripPlanner with a pruned Chicago-only graph — heavyweight, not justified for one mode.

### Scoring — "given a candidate bike polyline, judge how good it is"

You don't need a routing engine at all. You need:
- One or more static **classification layers** (CDOT infrastructure, Mellow curation, OSM cycle tagging).
- A geometry library to intersect a polyline against those layers (CoreLocation + MapKit can do this; better: bundle a small spatial index).
- A scoring function that produces a number `PortfolioEvaluator` can rank against.

This works *over* whatever produced the polyline — `MKDirections`, user history, a hand-drawn route — and gives "this candidate is 70% protected lane, 20% mellow street, 10% mixed traffic" as a rank signal.

### Both

Routing engine produces N candidate polylines per OD; scoring layer ranks them; portfolio picks. Most expressive, also the most build.

**The brainstorm doesn't pick a path.** Scoring-only is the cheapest start and might be all that's needed for door-to-door ranking. Routing is required only if Cozy Fox is meant to *propose* novel bike paths the user hasn't tried — which is a separate product question.

## Data inventory

What's free and bundleable today, in rough order of value per byte:

| Source | What | Format | License | Size estimate |
|---|---|---|---|---|
| [City of Chicago Bike Routes](https://data.cityofchicago.org/Transportation/Bike-Routes/hvv9-38ut) | CDOT infrastructure by design type | GeoJSON / Shapefile | Open Data | ~MB-class, bundleable |
| [Chicago/osd-bike-routes](https://github.com/Chicago/osd-bike-routes) | Mirror of the same | Shapefile | Open | same |
| `mellowroute.fixture` in mellow-bike-map | Hand-curated mellow streets | SQL fixture (osm2pgrouting edge IDs) | MIT | small, but needs transform to lat/lon polylines |
| OSM cycle network | `highway=cycleway`, `bicycle=designated`, named cycle routes | Overpass / PBF extract | ODbL (attribution) | extractable to MB-class via Overpass query |
| Apple Maps base map | Used implicitly via MKDirections / MapKit | — | first-party | n/a |

What's not bundleable cheaply:
- Mapbox tiles or routing — needs an account.
- Mellow Bike Map's *routing output* — needs the server running.
- Hill profiles / wind exposure — derivable from OSM elevation + weather API, not packaged.

OSM ODbL attribution: a one-line credit in the app's about screen covers it.

## How this composes with the existing system

Assuming a scoring-layer approach for now (cheapest, fits no-backend, leaves the routing question for later):

1. **Build-time** — pull CDOT GeoJSON + extracted Mellow polylines + OSM cycle-tagged ways into bundled catalogs in `TransitModels`. Probably one combined "bike network catalog" with per-segment fields: `infrastructure_class` (protected/buffered/greenway/off-street/shared/none), `mellow_score` (0 / 0.5 / 1 from Mellow fixture), `street_class` (residential/arterial/highway from OSM).
2. **At query time** — for each candidate bike leg in a journey, produce the polyline (from `MKDirections.cycling`, from user history, or from the leg's start/end docks plus a straight-line if nothing else is available), intersect it against the bundled catalog, and emit a quality vector.
3. **PortfolioEvaluator consumes** the quality vector as a rank input alongside dock state, predicted duration, weather, and any other portfolio signals. Per `feedback_cozyfox_invisible_predictions` the score never reaches the UI as a string — it shapes which bike candidate gets shown, never explains why.
4. **`BikeSpeedTracker` calibration improves**: per-infrastructure-class personal speed estimates ("on protected lanes I ride at 14 mph, in mixed traffic 11 mph") — same shape as the existing tracker, finer grain.
5. **Synthetic-routes corpus grades it**: bike legs on canonical corridors get the same `predicted vs. actual` treatment as transit legs (`SYNTHETIC_ROUTES.md`). The infrastructure-aware feature vector becomes a Tier 1 or 2 feature for the model.
6. **Confidence-interval surfaces it**: per-corridor bike-leg coverage and sharpness in the debug surface (`CONFIDENCE_INTERVALS.md`) — including a "the user took Milwaukee Ave but we ranked Damen above it" gap signal that, if it appears, tells us the scoring layer is wrong for that corridor.

If a routing engine gets added later, it slots upstream of step (2): generate N polyline candidates instead of relying on a single source. Nothing downstream of step (2) changes.

## The home-box angle

`SYNTHETIC_ROUTES.md` already opens the door to a user-owned always-on box for the corpus recorder. If that box exists, hosting Mellow Bike Map's Docker stack on it costs ~nothing additional and gives Cozy Fox a routing API that respects the local methodology — without breaking the "no backend, user's own infra only" framing. This is the cleanest path to *routing* (as opposed to just scoring) without surrendering the architectural rule.

Worth keeping on the table as a Phase-3+ option, contingent on the home box already existing for other reasons. Not a justification on its own.

## Open questions

- **Routing vs. scoring vs. both.** Named above; the brainstorm explicitly does not pick. Recommendation: defer until door-to-door has run for a while and we can see *whether the inability to distinguish bike paths is actually hurting rank quality*. The confidence-interval surface answers this directly.
- **Mellow fixture extraction.** The fixture is `osm2pgrouting` edge IDs, not lat/lon polylines. Round-tripping it into something MapKit-friendly is a one-time scripting job (load the fixture into a throwaway PostGIS, join against the geometry table, export as GeoJSON). Easy but not trivial.
- **Currency of the curated data.** CDOT data updates regularly. The Mellow fixture updates only when its maintainer commits. Both could go stale; the bundled catalog should encode a `data_as_of` field and the daily-refresh payload (`SYNTHETIC_ROUTES.md` Phase 5c) could refresh it.
- **Does Chicago even need this?** Chicago is a grid. A human picks a bike route well from memory after a few weeks of riding. The question is whether *automating* that picking improves door-to-door enough to justify the data layer. Probably yes for cold corridors (new neighborhoods, occasional trips) and no for daily commutes (where the user's history dominates the rank). The portfolio-evaluator slot is mainly to *not embarrass ourselves* on cold corridors.
- **Wind / weather coupling.** Bike leg duration depends on headwind component; route choice can too (Lakefront Trail is exposed, Milwaukee Ave is sheltered). Weather is already Tier 2 in `SYNTHETIC_ROUTES.md`; bike scoring should consume the same feature vector rather than build its own.
- **Classic vs. e-bike scoring.** E-bike removes hill / headwind penalties and shrinks the "protected lane vs. mixed traffic" comfort gap (rider is faster either way). The scoring function should accept bike type as input and weight infrastructure-class differently. Likely a multiplier on the mixed-traffic penalty.
- **Network effects from the curated layer.** If the Mellow fixture is incorporated and someone disagrees with a tagging, where do they push back? Probably "they don't, because the scoring layer is invisible and a wrong-tagging just nudges rank slightly." But worth noting that we're inheriting someone else's editorial judgment.
- **License attribution.** OSM ODbL credit, MIT-from-Mellow credit, City of Chicago Open Data credit. One-screen list of credits, standard practice.
- **Predictions stay invisible.** The scoring vector never becomes a user-facing string ("this route is mellower"). It changes rank, prefetch, defaults, what tiles show — and only that. Same rule as everywhere else.

## What this isn't

- **A turn-by-turn navigation feature.** Cozy Fox is glanceable; if the user wants turn-by-turn, they tap through to Apple Maps. The bike work here is for *deciding which leg to recommend*, not for guiding the ride itself.
- **A bike-infrastructure visualizer.** CNT BikeChi already does that, well. Re-skinning their map inside Cozy Fox adds nothing.
- **A Divvy alternative.** All of this builds on top of the existing `DivvyGBFSClient` dock/bike state. We're refining how the bike leg is *ranked*, not replacing how it's *fetched*.

## Connection to existing pieces

- **`docs/DOOR_TO_DOOR.md`** — bike scoring becomes one feature among many in the composition math. The catching-probability and recovery-cost framing for classic-Divvy-with-dock-full doesn't change; this just sharpens the "which bike leg" choice that feeds in.
- **`docs/SYNTHETIC_ROUTES.md`** — bike legs on canonical corridors get the same `(predicted, retrospective truth)` grading. Infrastructure features become Tier 1 inputs once available. The corpus's bike submodel may live in `../divvy-observer/`.
- **`docs/CONFIDENCE_INTERVALS.md`** — the metric that decides whether this work is justified. If route-surfacing CI on bike-heavy corridors is already tight, this is a "nice to have"; if it's wide, this is the lever.
- **`Packages/TransitCore/Sources/TransitModels/`** — natural home for bundled bike network catalogs, peer to `CTAStations.json` and friends. Probably `BikeNetwork.json` or `ChicagoBikeNetwork.geojson` with prewarming hooked into `Catalogs.prewarm()`.
- **`Packages/TransitCore/Sources/TransitDomain/`** — natural home for the scoring function. Pure, `Clock`-free, testable with fixture polylines.
- **`BikeSpeedTracker`, `BikeRouteStore`** — extend to per-infrastructure-class speed estimates if/when scoring lands.
- **`PortfolioEvaluator`** — consumes the quality vector as a rank input.
- **`../divvy-observer/`** — likely where the central bike-prediction model lives (per `SYNTHETIC_ROUTES.md`'s mode split). Coordination point if scoring features become model inputs.
- **`feedback_cozyfox_invisible_predictions`** — scoring outputs shape state, never copy. No "we chose this because it's mellower" text anywhere.
