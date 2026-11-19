# Architecture

## The model

- **Tiles**: the world is cut into zoom-14 slippy-map tiles (~1.5 km). Each is built from an
  Overpass query (with a 400 m buffer so streets crossing the edge are whole) and owns the
  segments whose length-midpoint lies inside it. The app loads the 3×3 tiles around you and
  more as you pan or run, so you can play anywhere with OSM streets.
- **Segment**: a stretch of street between two junctions (or between name changes),
  from OSM. It has a stable ID (a hash of its end nodes). Pavements alongside a road are
  folded into that road, so running the pavement credits the road.
- **Tokens**: the dots along every street, one per 10 m (`tokens.metresPerToken`, at least one
  per street). Each coin you collect is one token, and leaderboards (nearby =
  same ~25 km region, global, friends, club) rank by tokens captured, all time.
- **Invites**: a friend who joins with your code gets 30 days of Pro at once; you get 30 days
  when they finish their first live run (max 12). Stored as the `pro_invite` entitlement, next
  to RevenueCat's `pro`; `has_pro()` and the app accept either.
- **Capture**: per coin. A run takes every coin its matched path passes within
  `capture.coinReachMetres` (5 m, along the street), so half a street takes half its coins.
  Coin ownership is keyed `"<segment id>#<i>"` (`Coins.swift` / `chomp/coins.ts`). Each street
  with coins taken gets one capture record (*captured*, or *stolen* if any coin was a rival's)
  carrying `tokens` and the coin indexes; coins you already held are *refreshed*. Later capture
  still wins per coin. Imports: Strava is exploration only; Health runs within the import
  window take the coins they passed. `capture.coverageThreshold` (80%) now only decides when
  a street counts as explored. Bots run whole streets and take every coin.
- **Decay**: ownership strength falls linearly from 1 to 0 over 21 days since the last visit.
  It's derived from `last_visited_at` and never stored, and an hourly cron clears faded streets.
- **Blocks**: faces of the street graph. Holding every bounding segment pays a one-off bonus
  (base plus area), with a 24-hour cooldown on re-awards.
- **Power pellets**: one landmark per tile a day. Running within 30 m starts a 10-minute *frenzy*:
  2× points, and a rival's street flips at 40% coverage.
- **Bonus streets**: one named street per tile a day, with a 2–3× time window.
- **Bots**: simulated rivals ("Bot Dusk" etc.), always labelled as bots. They walk the
  graph and raid near your territory. Locally they keep solo play lively; on the server
  they live per district (4×4 tiles) wherever players hold streets.

Every number lives in `shared/rules.json`. The app bundles it, and the Edge Functions get a
copy (`tools/sync-rules.sh`; a test fails if the copies drift).

Daily spawns are deterministic: SplitMix64 seeded by FNV-1a of `tile|Europe/London date`.
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
- Late uploads and Apple Health imports capture streets if the run ended within 7 days
  (`imports.captureWindowHours`); older runs, and Strava history, count for exploration only.
- *Later capture wins* also applies to imports: an old run can't take a street from someone
  who ran it more recently.

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

## No fading

Streets stay yours until someone else runs them (`rules.decay.enabled = false`). The
engines treat the decay interval as infinite, so strength stays at 1. The database mirrors
this in `game_config` (migration 20261122000000_no_decay.sql): `ownership_strength()`
returns 1 and the hourly `decay_sweep()` does nothing. The 21-day fade comes back if the
switch is turned on in both places.

## Coins, and capture areas (off)

Every street is drawn as a row of coins, one per token (`rules.tokens.metresPerToken`, 10 m),
evenly spaced: a small pearl-silver bead when nobody holds the coin; full-size struck coins (bevelled rim, domed face, embossed four-point star) in gold when you hold it and in a rival's own
colour when they do (a rival whose colour reads as gold or orange is shown red, so gold
always means yours), fading with strength. There are no street lines. Coin art is drawn in code
(`CoinIcon` in `GameMapView.swift`) per colour and placed with a MapLibre symbol layer.
Overlapping coins are dropped when zoomed out, so the coins never merge into a line.

Capture areas (block bonuses and conquering a map square) are switched off with
`rules.blocks.enabled = false`. Both engines skip them, the UI hides them, and the tests
still cover them with the switch on. The server applies the switch from its bundled
copy of rules.json, so it takes effect there at the next Edge Function deploy. Until
then, the server can still add block-bonus points (points only: tokens and the
leaderboard are unaffected).

Server: migration `20261123000000_coins.sql` re-keys `segment_ownership` by coin (with a
derived `street_id` that keeps the cascade on segments), expands existing street ownership to
coins, adds `captures.tokens`, sums coins on the leaderboard, keeps events and "lost"
notifications to one per street per run, and counts "streets held" as streets with any of
your coins. Run it before deploying Edge Functions that write coin IDs. The app accepts both
coin and street rows, and migrates local street ownership to coins on load.

## Club battles

One club per player (`memberships_one_club_idx`). Captures are stamped with the player's club
when they're made (trigger `captures_stamp_club`), so a club's tally is the coins its members
collected while in it, and switching clubs doesn't move old coins. `club_leaderboard('nearby'|
'global', tile)` ranks clubs (nearby = same ~25 km region); `my_club()` returns the tally, rank
and each member's contribution. Joining or starting a club leaves the current one; a captain
who leaves hands over to the longest-standing member, and an empty club is deleted. Starting a
club needs Pro; joining is free. Migration: `20261125000000_club_battles.sql`.

## Health runs on launch

On launch and when returning to the app, Chomp looks for running workouts recorded by other
apps within the capture window (7 days) and offers to import them in one alert. Each workout
is offered once (`PlayerProfile.healthOffered`), and it only checks after the player has
already answered the Health permission sheet.

## Builds

`codemagic.yaml` builds, tests and uploads to App Store Connect (see its header for the
one-time setup). The app icon is drawn by `swift tools/make-icon.swift`.

## On-device extras

These run on the phone only and need no server:

- **Weekly goals and streaks** (`ChompKit/Game/Goals.swift`) come from run history. Everyone
  gets the same three goals each week, seeded from the ISO week in UK time. The streak counts
  consecutive days with a run; if a streak of two or more days would end tonight, a local
  notification goes out at 7pm. Release builds ignore simulated runs.
- **Route planner** (`ChompKit/Game/RoutePlanner.swift`) tries 24 randomised walks over the
  junction graph, scored by wanted streets per metre and closeness to the target distance.
  Each walk closes the loop by Dijkstra back to the start. The aims are: grab neutral or rival
  streets, save your fading streets, or explore streets you've never run. Simulated runs follow
  the planned loop.
- **Spoken updates** (`Chomp/Services/RunVoice.swift`) use AVSpeechSynthesizer. They cover
  batched captures with token counts, steals, frenzy, pause/resume and a split each km or mile.
  The `audio` background mode keeps it talking when the phone is locked.

## Not built yet

- **Push delivery** is built but needs setup: run migration `20261124000000_push.sql`, set the
  Edge Function secrets APNS_KEY (.p8 contents), APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC,
  then deploy `send-push` (a cron job runs it every minute). The app registers its token via
  `register_push_token`; settings choose "coins lost" and "bot raid" pushes.
- **A web admin UI** for `review_queue` and reports. For now, use the Supabase table editor.
- **The watch app** is built but isn't embedded by default. Set `CHOMP_EMBED_WATCH=true`
  once the watchOS runtime is installed.
