# Architecture

## The model

- **Segment**: a stretch of street between two junctions (or between name changes),
  from OSM. It has a stable ID (a hash of its end nodes). Pavements alongside a road are
  folded into that road, so running the pavement credits the road.
- **Capture**: covering at least 80% of a segment's length in one run (`capture.coverageThreshold`).
  A neutral street is *captured*, a rival's street is *stolen*, and your own street is *refreshed*
  (its decay timer resets, but it earns no points).
- **Decay**: ownership strength falls linearly from 1 to 0 over 21 days since the last visit.
  It's derived from `last_visited_at` and never stored, and an hourly cron clears faded streets.
- **Blocks**: faces of the street graph. Holding every bounding segment pays a one-off bonus
  (base plus area), with a 24-hour cooldown on re-awards.
- **Power pellets**: 3 landmarks a day. Running within 30 m starts a 10-minute *frenzy*:
  2× points, and a rival's street flips at 40% coverage.
- **Bonus streets**: 2 named streets a day with 2–3× time windows.
- **Bots**: simulated rivals ("Bot Dusk" etc.), always labelled as bots. They walk the
  graph and raid near your territory. Locally they keep solo play lively; on the server
  they keep quiet towns lively.

Every number lives in `shared/rules.json`. The app bundles it, and the Edge Functions get a
copy (`tools/sync-rules.sh`; a test fails if the copies drift).

Daily spawns are deterministic: SplitMix64 seeded by FNV-1a of `slug|Europe/London date`.
So offline clients, online clients and the server all agree without a network round-trip.

## Map matching

This is a custom Newson–Krumm HMM over Chomp's own segment graph, not a hosted
map-matching API. That means results come out directly as segment IDs plus the covered
intervals along each segment, at zero cost, and it can run on the device:

1. Filter fixes with accuracy over 40 m, thin points closer together than 4 m, and split at
   gaps (over 60 s or 200 m).
2. Candidates: up to 6 segments within 30 m (uniform-grid spatial index).
3. Emission is Gaussian on distance (σ = 8 m). The transition compares route distance with
   straight-line distance (β = 6) using a bounded Dijkstra between candidates.
4. Viterbi. An HMM break (no plausible transition) closes the chunk and restarts.
5. The chosen routes become `CoveragePiece`s (segment, from/to offsets, timestamps). They're
   unioned per segment into an `IntervalSet`, and the coverage ratio comes from that.

`LiveCaptureTracker` runs the same matcher over a sliding window during a run to give
*provisional* captures: the pellet-eating feedback, Live Activity and watch updates.

## Authority

| | Offline / solo | Online |
|---|---|---|
| Who decides captures | `GameEngine` on device | `resolve-run` Edge Function |
| Ownership store | `GameState` JSON in Application Support | `segment_ownership` (private) |
| Rivals | Local bots | Real players + server bots |

Online, the app uploads the **privacy-trimmed** trace and keeps its local result as provisional.
The server re-matches, runs anti-cheat, applies the rules and writes everything in a single
`apply_run_result` transaction. The app then replaces its result with the server's.

- Concurrent runs: ownership writes use *later capture wins* under a row lock.
- Retries: idempotent on run ID.
- Late uploads (over 48 h after the run) count for exploration only, so captures can't be backdated.

Clients **never** write ownership, captures or runs. RLS has no insert or update policies on
those tables, so only the service role can write them.

### What other players can see

- `segment_ownership_public` (view): owner name and colour, with times rounded to the hour.
  Private players and players you've blocked are hidden, and shadow-restricted players are
  visible only to themselves.
- `segment_ownership_feed` (table, for Realtime): a trigger-maintained public mirror. Realtime
  honours RLS and the raw table is private, so a mirror is needed. Private and
  shadow-restricted players are never added to it.
- On the map, rivals appear only as their streets plus coarse area markers snapped to a
  ~300 m grid. Live positions, run start points and traces are never shared.

## Anti-cheat

`AntiCheat.evaluate` (in Swift, plus a TypeScript port) checks:

- Teleports (over 60 km/h jumps).
- Sustained speed (over 25 km/h for 20 s).
- Bursts of impossible acceleration.
- Machine-straight constant-speed stretches.
- Synthetic traces (identical accuracy and perfectly regular timestamps).
- CoreMotion automotive or cycling share.
- Cadence too low at running pace.
- Heart rate too low at running pace (a weak signal).

Outcomes:

- **Excluded windows** (too fast, vehicle, teleport): coverage in those windows is discarded,
  and the summary shows "Too fast to be running".
- **Under review** (any high flag, or 3 medium flags): no ownership changes at all. The run goes
  into `review_queue` with its evidence.
- **Rate limits**: 400 captures per run and 800 per day.
- **Shadow restriction** (`user_trust.shadow_restricted`): the player sees normal results,
  but nothing reaches the shared map.

## Privacy

- **Privacy zones**: radius plus 60 m random jitter on the centre. The trace is trimmed until
  the runner first leaves every zone and after they last enter one. This happens **on device,
  before upload**. A consequence is that you can't capture streets right at your front door
  by starting or ending there. That's deliberate: otherwise the street would reveal where you live.
- Raw traces go to a private Storage bucket that only the owner can read.
- Private mode keeps you off leaderboards and the shared map.
- Account deletion (`delete_own_account`) removes everything, including owned streets.

## Server components

| Function | Trigger | Job |
|---|---|---|
| `resolve-run` | App, after each run | Validate, match, anti-cheat, resolve, apply |
| `ghost-tick` | pg_cron hourly | Move bots, record raids → `notification_outbox` |
| `spawn-daily` | pg_cron 00:05 | Record the day's pellets/bonus streets (informational; spawns are deterministic) |
| `revenuecat-webhook` | RevenueCat | `entitlements` (Pro gates clubs + Strava import server-side) |
| `strava-import` | App (Pro) | OAuth code exchange, import runs as exploration only |

All five share the TypeScript port in `functions/_shared/chomp`, and its pure core is
`_shared/resolve.ts`. Under Node, `backend/tests` checks it against ChompKit's own outputs.

## Not built yet

- **Push delivery.** Lost-street and bot-raid messages are written to `notification_outbox`,
  but nothing sends them to APNs yet. That needs a push key, the `aps-environment`
  entitlement and device-token registration in the app. Locally, bot raids and fade warnings
  already use local notifications.
- **A web admin UI** for `review_queue` and reports. For now, use the Supabase table editor.
- **The watch app** is built but isn't embedded by default. Set `CHOMP_EMBED_WATCH=true`
  once the watchOS runtime is installed.
