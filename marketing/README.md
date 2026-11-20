# Marketing assets

| File | Use |
|---|---|
| post1-carousel-1…4.png | Instagram carousel, 1080x1350 (4:5) |
| post2-make-running-fun.png | Instagram single post, 1080x1350 |
| reel1-run-is-a-game.mp4, reel2-steal-and-compete.mp4 | Instagram reels, 1080x1920, 30 fps, silent (not in git: regenerate below) |
| instagram-profile.png | Instagram profile picture, 1080x1080 (Instagram crops it to a circle) |
| CAPTIONS.md | Captions, hashtags and posting tips |

The leaderboard in these uses made-up runner names (the app's `-marketing` mode).

## Regenerating
1. Raw stills: run `ChompUITests/ScreenshotTests/testAppStoreScreens` (see docs/APP_STORE.md).
2. Posts: `swift tools/make-posts.swift <raw stills dir> marketing`
   Profile picture: `swift tools/make-profile-pic.swift marketing`
3. Reel footage: record the 6.9" simulator while the footage test runs, noting when recording started.
   The test plays a demo week in Battersea, London, then runs a planned 1.4 km loop (so the route is
   tidy). For somewhere else, add `TEST_RUNNER_CHOMP_REEL_AT=lat,lon` and set the simulator's location
   there too (`xcrun simctl location <sim> set lat,lon`). Uninstall the app first for a fresh demo.
   ```
   xcrun simctl io <sim> recordVideo --codec h264 --force <dir>/raw.mp4 &
   sleep 2; python3 -c "import time;print(time.time())" > <dir>/recstart.txt
   TEST_RUNNER_CHOMP_SCREENSHOTS=1 TEST_RUNNER_CHOMP_SHOTS_DIR=<dir> xcodebuild test -project ios/Chomp.xcodeproj \
     -scheme Chomp -destination 'id=<sim>' -only-testing:ChompUITests/ScreenshotTests/testReelFootage
   kill -INT %1
   ```
4. Reels: `swiftc -O tools/make-reels.swift -o /tmp/make-reels && /tmp/make-reels <dir> marketing`
