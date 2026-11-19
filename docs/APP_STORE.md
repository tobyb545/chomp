# App Store listing (draft)

**Name:** Chomp: Run Your Streets
**Subtitle:** Claim your town, one run at a time
**Category:** Health & Fitness (secondary: Games)
**Age rating:** 4+ (user-generated content limited to display names. Report and block are built in.)

## Promotional text (170)
Every street in town is covered in pellets. Run one to eat them and paint it your colour. Your rivals will want it back.

## Description
Chomp turns your runs into a game of territory.

Every street in your town is lined with pellets. Run a street and you eat them, and the street turns your colour. Keep running and you'll fill whole blocks, climb your town's leaderboard and push towards conquering the whole map.

But your streets don't stay yours by themselves. Rivals can run them and win them back, and any street you don't revisit fades to neutral after three weeks. So there's always a reason to head out the door, and a new route to try.

• REAL STREETS: built from OpenStreetMap for your town. Run the pavement and the road counts.
• POWER PELLETS: three landmarks light up each day. Reach one to start a 10-minute frenzy and win rival streets twice as fast.
• BONUS STREETS: daily streets worth double or triple at set times.
• BLOCKS: claim every street around a block for a big bonus.
• RIVALS AND CLUBS: leaderboards for your town, county, friends and club.
• SOLO TOO: no one nearby yet? Clearly labelled bots keep the map moving.
• FAIR PLAY: driving, cycling and GPS tricks don't count. Every run is checked.
• PRIVATE BY DESIGN: privacy zones hide where your runs start and end. No one ever sees your live location or your routes. Private mode keeps you off the shared map entirely.
• LIVE ACTIVITY AND WIDGETS: streets and pellets on your Lock Screen as you run.
• APPLE HEALTH: runs are saved as workouts. Import your past runs to see how much of town you've already explored.

Chomp Pro (optional) adds trail styles and colours, run replays and GIF export, detailed stats, Strava import and club creation. Pro never helps you capture streets: everyone plays by the same rules.

Map data © OpenStreetMap contributors.

## Keywords (100)
running,run,territory,streets,map,game,conquer,town,fitness,jogging,gps,explore,city,club,leaderboard

## What's new (1.0)
First release. Go and eat some streets.

## Screenshots (6.9" and 6.5", then 6.1" auto-scaled)
1. **Home map**, with owned streets glowing and pellet dots. Caption: "Run a street. Eat the pellets. It's yours."
2. **Mid-run HUD**, with the streets counter and a "just ate" toast. Caption: "Every street you run turns your colour."
3. **Frenzy**: the power pellet hit, with the frenzy timer. Caption: "Hit a power pellet. Win streets back twice as fast."
4. **Run summary**: +points, streets won back, block bonus. Caption: "Fill a block for a big bonus."
5. **Leaderboard** (town / friends / club). Caption: "Take your town."
6. **Privacy zones** screen. Caption: "Your routes and home stay private."

Capture them with the `-demo` launch argument, which seeds a week of runs (debug builds only).

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
  build with a demo account, or run anywhere in West Byfleet, Surrey (UK).
