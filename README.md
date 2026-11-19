# Chomp

Run any street, anywhere, to collect the coins (tokens) on it: they turn your colour.
They stay yours until someone else runs the street.
An original arcade-styled iOS game: no Pac-Man names, characters, sounds or art.

**Status:** the app is feature-complete and fully playable offline (solo play against
labelled bots). Online play runs on Supabase. The backend is deployed to the live
project; a real signed-in run on a phone is still to be tried. See [docs/SETUP.md](docs/SETUP.md).

Besides capturing streets: token leaderboards, invites (a free month of Pro), weekly goals
and a daily run streak, a route planner that draws a loop through streets worth running,
spoken updates during a run, and Apple Health import.

| | |
|---|---|
| App | SwiftUI, iOS 18, Swift 6 · `ios/` (XcodeGen) |
| Game logic | `ios/ChompKit` (Swift) and its TypeScript port in `backend/supabase/functions/_shared/chomp` |
| Map | MapLibre Native + OpenFreeMap tiles: no API key, no usage fees |
| Streets | OpenStreetMap via Overpass, built into ~1.5 km tiles on demand (on the phone or server) · `ChompKit/Map/Tiles.swift` |
| Backend | Supabase: Postgres/PostGIS + RLS, Edge Functions, Realtime, pg_cron |
| Pro | RevenueCat (cosmetic and convenience only: never affects captures) |

## Quick start (offline)

```sh
brew install xcodegen
cd ios && xcodegen generate && open Chomp.xcodeproj
```

Run the **Chomp** scheme. In the simulator, START RUN offers a simulated run.
Debug launch arguments: `-demo` seeds a week of runs, `-autorun` starts a simulated
run, and `-summary` opens the last run summary.

## Tests

```sh
# Swift: ChompKit (matching, rules, anti-cheat, bots, privacy, routes, goals, parity fixture)
cd ios && xcodebuild test -project Chomp.xcodeproj -scheme ChompKit -destination 'platform=iOS Simulator,name=iPhone 16'
# Everything on iOS: ChompKit + app unit tests (profile migration, invites) + UI walkthrough
# (intro, every sheet, route planner, settings, a simulated run to its summary; ~3 min)
cd ios && xcodebuild test -project Chomp.xcodeproj -scheme Chomp -destination 'platform=iOS Simulator,name=iPhone 16'
# TypeScript: server port parity and resolve-run core (Node 22.6+, no npm install)
cd backend && npm test
# SQL: RLS policies (needs `supabase start`)
cd backend && supabase test db
```

The Swift tests write `shared/fixtures/parity.json`, and the Node tests check that the
server reaches the same decisions. The Node tests write `shared/fixtures/server-response.json`,
and the Swift tests decode it. After changing game logic, run Swift, then Node, then Swift again.

## Layout

```
ios/            App, ChompKit framework, widgets + Live Activity, watch app, tests
backend/        Supabase migrations, Edge Functions, pgTAP + Node tests
shared/         rules.json (the single source of game numbers) and test fixtures
tools/          rules sync
docs/           Architecture, setup, App Store listing
```

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Map data © OpenStreetMap contributors (ODbL).
Tiles: OpenFreeMap.
