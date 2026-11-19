# App Store listing (draft)

**Name:** Chomp: Run Your Streets
**Subtitle:** Claim your streets, one run at a time
**Category:** Health & Fitness (secondary: Games)
**Age rating:** 4+ (user-generated content limited to display names. Report and block are built in.)

## Promotional text (170)
Every street, wherever you are, is covered in pellets. Run one to eat them and paint it your colour. Your rivals will want it back.

## Description
Chomp turns your runs into a game of territory.

Every street around you is lined with gold coins, at home or on holiday. Run a street and its coins turn your colour. Keep running to collect more tokens than anyone nearby and climb the leaderboard.

Your streets stay yours until someone else runs them, and rivals will try. Win them back by running them again.

• REAL STREETS, ANYWHERE: built from OpenStreetMap wherever you run. Run the pavement and the road counts.
• POWER PELLETS: three landmarks light up each day. Reach one to start a 10-minute frenzy and win rival streets twice as fast.
• BONUS STREETS: daily streets worth double or triple at set times.
• RIVALS AND CLUBS: leaderboards for nearby, worldwide, friends and club.
• SOLO TOO: no one nearby yet? Clearly labelled bots keep the map moving.
• FAIR PLAY: driving, cycling and GPS tricks don't count. Every run is checked.
• PRIVATE BY DESIGN: privacy zones hide where your runs start and end. No one ever sees your live location or your routes. Private mode keeps you off the shared map entirely.
• LIVE ACTIVITY AND WIDGETS: streets and pellets on your Lock Screen as you run.
• APPLE HEALTH: runs are saved as workouts. Forgot to start Chomp? Add a run from Apple Health afterwards and it still counts.

Chomp Pro (optional) adds trail styles and colours, run replays and GIF export, detailed stats, Strava import and club creation. Pro never helps you capture streets: everyone plays by the same rules.

Map data © OpenStreetMap contributors.

## Keywords (100)
running,run,territory,streets,map,game,conquer,neighbourhood,fitness,jogging,gps,explore,city,club,leaderboard

## What's new (1.0)
First release. Go and eat some streets.

## Screenshots (6.9", 1320x2868; App Store scales them for smaller iPhones)
Ready to upload in `docs/screenshots/`, in this order:
1. Map: "Make running fun again"
2. Mid-run: "Run it. Own it."
3. Leaderboard: "Compete with the world"
4. Planned route: "Plan a loop, take the block"
5. Run summary: "Every run counts"
6. Goals and streak: "Keep your streak alive"

To regenerate (debug build, iPhone 16 Pro Max simulator, status bar overridden to 9:41):
```
TEST_RUNNER_CHOMP_SCREENSHOTS=1 TEST_RUNNER_CHOMP_SHOTS_DIR=/tmp/chomp-shots \
  xcodebuild test -project ios/Chomp.xcodeproj -scheme Chomp -destination 'name=<6.9" sim>' \
  -only-testing:ChompUITests/ScreenshotTests
swift tools/make-screenshots.swift /tmp/chomp-shots docs/screenshots
```
The test launches with `-demo -marketing` (a seeded week of runs, no "Simulated" badges).

## App Privacy (nutrition label)
| Data | Linked to you | Used for | Tracking |
|---|---|---|---|
| Precise location | Yes | App functionality (matching runs to streets) | No |
| Health & fitness (workouts, heart rate) | Yes | App functionality, anti-cheat | No |
| Name (display name) | Yes | App functionality | No |
| User ID | Yes | App functionality | No |
| Purchases | Yes | App functionality (RevenueCat) | No |

Not collected: contacts, browsing history, advertising data. No third-party advertising or analytics SDKs.

## Review notes
- Location is requested only when the player taps Allow in onboarding (with an explanation first) or starts their first run. It is never requested at launch: the map uses a passive location manager until permission is granted.
- Background location is used only during an active run, to keep recording with the screen off.
  The blue indicator and the Live Activity are always shown.
- Bots are always named "Bot …" and badged as bots.
- No real-money wagering. Pro is a standard auto-renewing subscription.
- To test without running: debug builds offer a simulated run. For review, use a TestFlight
  build with a demo account, or run anywhere: streets load wherever you are.
