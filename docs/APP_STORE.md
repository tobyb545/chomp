# App Store listing (draft)

**Name:** Chomp: Run Your Streets
**Subtitle (30):** Running, but it's a game
**Category:** Health & Fitness (secondary: Games)
**Age rating:** 4+ (user-generated content limited to display names. Report and block are built in.)

## Promotional text (170)
Every street is covered in coins. Run past them to make them yours, steal your rivals' and climb the global leaderboard. Running, but it's a game.

## Description
Chomp makes running fun again by turning your runs into a game of territory.

Every street around you is lined with coins, at home or on holiday. Run past them and they turn your colour. Grab more than anyone nearby and climb the leaderboards, from your neighbourhood to the whole world.

Your coins stay yours until someone else runs past them, and rivals will try. Steal theirs back by running their streets.

• REAL STREETS, ANYWHERE: built from OpenStreetMap wherever you run. Run the pavement and the road counts.
• STEAL FROM RIVALS: run a rival's street to take their coins. Defend your patch by running it again.
• POWER-UPS: three landmarks light up each day. Reach one to start a 10-minute frenzy and win rival streets twice as fast.
• BONUS STREETS: daily streets worth double or triple at set times.
• CLUB BATTLES: start or join a club. Every coin members collect counts towards the club's tally, ranked nearby and worldwide.
• LEADERBOARDS: nearby, worldwide, friends and clubs.
• ROUTE PLANNER: get a loop that grabs the most coins for the distance you want.
• RIVALS FROM DAY ONE: there's always someone to beat, from your very first run.
• FAIR PLAY: driving, cycling and GPS tricks don't count. Every run is checked.
• PRIVATE BY DESIGN: privacy zones hide where your runs start and end. No one ever sees your live location or your routes. Private mode keeps you off the shared map entirely.
• LIVE ACTIVITY AND WIDGETS: coins and power-ups on your Lock Screen as you run.
• APPLE HEALTH: runs are saved as workouts. Ran with another app or your watch? Chomp spots the run when you open it and offers to add it.

Chomp Pro (optional) adds trail styles and colours, run replays and GIF export, detailed stats, Strava import and starting a club. Pro never helps you capture streets: everyone plays by the same rules.

Map data © OpenStreetMap contributors.

## Keywords (100)
running,run,territory,streets,map,game,conquer,neighbourhood,fitness,jogging,gps,club,leaderboard

## What's new (1.0)
First release. Go and grab some streets.

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
| Email address (only for email sign-in) | Yes | App functionality (sign-in codes) | No |
| Purchases | Yes | App functionality (RevenueCat) | No |

Not collected: contacts, browsing history, advertising data. No third-party advertising or analytics SDKs.

## Review notes
- Location is requested only when the player taps Allow in onboarding (with an explanation first) or starts their first run. It is never requested at launch: the map uses a passive location manager until permission is granted.
- Background location is used only during an active run, to keep recording with the screen off.
  The blue indicator and the Live Activity are always shown.
- In places with no other active players, computer-controlled rivals take part so the game
  works from the first run. They step back once real players are active in the area.
- No real-money wagering. Pro is a standard auto-renewing subscription.
- To test without running: debug builds offer a simulated run. For review, use a TestFlight
  build with a demo account, or run anywhere: streets load wherever you are.
