# Chomp

Run any street, anywhere, to eat the pellets on it and claim it in your colour.
Rivals can win them back; streets you don't revisit fade to neutral after 21 days.
An original arcade-styled iOS game: no Pac-Man names, characters, sounds or art.

**Status:** the app is feature-complete and fully playable offline (solo play against
labelled bots). Online play runs on Supabase. The backend is written and tested, but
it hasn't been deployed or connected yet: see [docs/SETUP.md](docs/SETUP.md).

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
# Swift: ChompKit (matching, rules, anti-cheat, bots, privacy, parity fixture)
cd ios && xcodebuild test -project Chomp.xcodeproj -scheme ChompKit -destination 'platform=iOS Simulator,name=iPhone 16'
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
