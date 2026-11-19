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

But your streets don't stay yours by themselves. Rivals can run them and win them back, and any street you don't revisit fades to neutral after three weeks. So there's always a reason to head out the door, and a new route to try.

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

## Screenshots (6.9" and 6.5", then 6.1" auto-scaled)
1. **Home map**, with owned streets glowing and pellet dots. Caption: "Run a street. Eat the pellets. It's yours."
2. **Mid-run HUD**, with the streets counter and a "just ate" toast. Caption: "Every street you run turns your colour."
3. **Frenzy**: the power pellet hit, with the frenzy timer. Caption: "Hit a power pellet. Win streets back twice as fast."
4. **Run summary**: tokens eaten, streets won back, weekly goals. Caption: "Every coin counts."
5. **Leaderboard** (nearby / friends / club). Caption: "Take your neighbourhood."
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
  build with a demo account, or run anywhere: streets load wherever you are.
