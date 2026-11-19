import XCTest

/// App Store screenshots. Skipped in normal runs; run with
///   TEST_RUNNER_CHOMP_SCREENSHOTS=1 xcodebuild test -only-testing:ChompUITests/ScreenshotTests ...
/// Raw captures go to $CHOMP_SHOTS_DIR (default /tmp/chomp-shots); tools/make-screenshots.swift frames them.
final class ScreenshotTests: XCTestCase {
    var app: XCUIApplication!
    var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CHOMP_SCREENSHOTS"] == "1", "screenshots only on request")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-marketing", "-dumpStory"]  // -dumpStory: saves the share card (Documents/story.png) for the website
        dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CHOMP_SHOTS_DIR"] ?? "/tmp/chomp-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func done() {
        let b = app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5)); b.tap()
    }

    func testAppStoreScreens() {
        app.launch()
        XCTAssertTrue(app.buttons["START RUN"].waitForExistence(timeout: 60))
        // Wait for the streets to download and the demo week to be played (fresh simulators are slow).
        let loading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Loading the coins around you'")).firstMatch
        let noTokens = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '0 coins held'")).firstMatch
        for _ in 0..<60 where loading.exists || noTokens.exists { sleep(3) }
        sleep(8)  // coins settle
        save("01-map")

        // Leaderboard
        app.buttons["Leaderboards"].tap()
        XCTAssertTrue(app.navigationBars["Leaderboards"].waitForExistence(timeout: 5))
        sleep(2)
        save("05-leaderboard")
        done()

        // Weekly goals and streak
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run streak'")).firstMatch
        if chip.waitForExistence(timeout: 5) {
            chip.tap(); sleep(2); save("06-goals"); done()
        }

        // Plan a loop that grabs coins, then run it.
        app.buttons["Plan a route"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Plan a route"].waitForExistence(timeout: 5))
        app.buttons["Grab coins"].tap()
        app.collectionViews.buttons["Plan a route"].tap()
        let show = app.buttons["Show it on the map"]
        XCTAssertTrue(show.waitForExistence(timeout: 30))
        show.tap()
        sleep(4)
        save("03-route")

        app.buttons["START RUN"].tap()
        let sim = app.buttons["Simulated run (demo)"]
        XCTAssertTrue(sim.waitForExistence(timeout: 5))
        sim.tap()
        XCTAssertTrue(app.staticTexts["HOLD TO FINISH"].waitForExistence(timeout: 10))
        sleep(45)
        save("02-run")
        app.staticTexts["HOLD TO FINISH"].press(forDuration: 1.6)
        XCTAssertTrue(app.staticTexts["Coins collected"].waitForExistence(timeout: 60))
        sleep(12)  // let the replay finish drawing
        save("04-summary")
    }

    // MARK: Reel footage
    // The host records the simulator screen; this test plays the scenes and writes
    // wall-clock marks to marks.json so tools/make-reels.swift can cut them.
    private var marks: [String: Double] = [:]
    private func mark(_ name: String) {
        marks[name] = Date().timeIntervalSince1970
        let data = try! JSONSerialization.data(withJSONObject: marks)
        try? data.write(to: dir.appendingPathComponent("marks.json"))
    }

    func testReelFootage() {
        app.launch()
        XCTAssertTrue(app.buttons["START RUN"].waitForExistence(timeout: 60))
        let loading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Loading the coins around you'")).firstMatch
        let noTokens = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '0 coins held'")).firstMatch
        for _ in 0..<60 where loading.exists || noTokens.exists { sleep(3) }
        sleep(6)
        mark("map")
        sleep(4)
        let mid = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        mid.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.42)), withVelocity: 120, thenHoldForDuration: 0.3)
        sleep(2)
        mark("startRun")
        app.buttons["START RUN"].tap()
        let sim = app.buttons["Simulated run (demo)"]
        XCTAssertTrue(sim.waitForExistence(timeout: 5))
        sim.tap()
        XCTAssertTrue(app.staticTexts["HOLD TO FINISH"].waitForExistence(timeout: 10))
        mark("run")
        sleep(55)
        mark("finish")
        app.staticTexts["HOLD TO FINISH"].press(forDuration: 1.6)
        XCTAssertTrue(app.staticTexts["Coins collected"].waitForExistence(timeout: 60))
        mark("summary")
        sleep(10)
        done()
        XCTAssertTrue(app.buttons["START RUN"].waitForExistence(timeout: 10))
        sleep(1)
        app.buttons["Leaderboards"].tap()
        XCTAssertTrue(app.navigationBars["Leaderboards"].waitForExistence(timeout: 5))
        mark("leaderboard")
        sleep(5)
        mark("end")
    }

    func testBadgeGrid() {
        app.launch()
        XCTAssertTrue(app.buttons["START RUN"].waitForExistence(timeout: 90))
        app.buttons["Profile and settings"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'BADGES' OR label BEGINSWITH 'Badges'")).firstMatch
        for _ in 0..<6 where !(header.exists && header.frame.minY > 120 && header.frame.minY < 400) { app.swipeUp(velocity: 400) }
        sleep(1)
        save("badges")
    }

    // MARK: Full tour (every screen, for review)

    private func tap(_ e: XCUIElement, _ name: String = "") {
        XCTAssertTrue(e.waitForExistence(timeout: 10), "missing \(e) \(name)")
        e.tap()
    }
    private func scrollTo(_ e: XCUIElement) {
        for _ in 0..<8 where !(e.exists && e.isHittable) { app.swipeUp(velocity: 500) }
    }
    private var prefix: String { ProcessInfo.processInfo.environment["CHOMP_TOUR_PREFIX"] ?? "" }
    private func shot(_ n: String) { sleep(1); save(prefix + n) }

    func testTourIntroAndOnboarding() {
        app.launchArguments = ["-demo", "-intro", "-marketing"]
        app.launch()
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 20))
        var n = 1
        shot("t00-intro-\(n)")
        while app.buttons["Next"].exists && n < 8 { app.buttons["Next"].tap(); n += 1; sleep(1); shot("t00-intro-\(n)") }
        app.terminate()
        app.launchArguments = ["-onboarding"]
        app.launch()
        tap(app.buttons["That's me"]); shot("t01-onboard-1")
        let field = app.textFields["Runner name"]; tap(field); field.typeText("Sam")
        shot("t01-onboard-2")
        tap(app.buttons["Next"]); shot("t01-onboard-3")
        tap(app.buttons["Not now"]); shot("t01-onboard-4")
        // Account step (only when online play is set up in this build).
        let email = app.textFields["Email address"]
        if email.waitForExistence(timeout: 3) {
            tap(email); email.typeText("sam@example.com"); shot("t01-onboard-5")
            tap(app.buttons["Not now"]); shot("t01-onboard-6")
        }
    }

    func testTourMainScreens() {
        app.launch()
        XCTAssertTrue(app.buttons["START RUN"].waitForExistence(timeout: 90))
        sleep(6); shot("t02-map")
        tap(app.buttons["Leaderboards"]); shot("t03-leader-runners")
        app.segmentedControls.buttons["Nearby"].tap(); shot("t03-leader-nearby")
        app.segmentedControls.buttons["Friends"].tap(); shot("t03-leader-friends")
        app.segmentedControls.buttons["Clubs"].tap(); shot("t03-leader-clubs")
        done()
        tap(app.buttons["Activity"]); shot("t04-activity"); done()
        tap(app.buttons["Coins nearby"]); shot("t05-streets"); done()
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run streak'")).firstMatch
        tap(chip); shot("t06-goals"); done()
        tap(app.buttons["Plan a route"].firstMatch); shot("t07-route-sheet")
        app.buttons["Grab coins"].tap()
        app.collectionViews.buttons["Plan a route"].tap()
        XCTAssertTrue(app.buttons["Show it on the map"].waitForExistence(timeout: 30)); shot("t07-route-planned")
        app.buttons["Show it on the map"].tap(); shot("t07-route-map")
        app.buttons["Clear planned route"].tap()

        tap(app.buttons["Profile and settings"]); shot("t08-profile-1")
        app.swipeUp(velocity: 500); shot("t08-profile-2")
        app.swipeUp(velocity: 500); shot("t08-profile-3")
        app.swipeUp(velocity: 500); shot("t08-profile-4")
        let firstBadge = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'First bite'")).firstMatch
        scrollTo(firstBadge); firstBadge.tap(); shot("t09-badge-detail")
        app.buttons["Done"].firstMatch.tap()
        let clubs = app.buttons["Clubs & friends"]; scrollTo(clubs)
        if !clubs.exists { app.swipeDown(velocity: 2000); app.swipeDown(velocity: 2000); scrollTo(clubs) }
        tap(clubs); shot("t10-clubs"); app.navigationBars.buttons.element(boundBy: 0).tap()
        let pro = app.buttons["Get Chomp Pro"]; scrollTo(pro)
        if pro.exists {
            pro.tap(); sleep(2); shot("t11-paywall")
            XCTAssertFalse(app.navigationBars["Profile"].isHittable, "paywall covers Profile")
            app.swipeDown(velocity: 2000); sleep(1)
        }
        let settings = app.buttons["Settings"]; scrollTo(settings); tap(settings); shot("t12-settings-1")
        app.swipeUp(velocity: 500); shot("t12-settings-2")
        app.swipeUp(velocity: 500); shot("t12-settings-3")
        let zones = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Privacy zones'")).firstMatch
        for _ in 0..<4 where !zones.exists { app.swipeDown(velocity: 500) }
        if zones.exists { zones.tap(); shot("t13-privacy-zones"); app.navigationBars.buttons.element(boundBy: 0).tap() }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<6 { app.swipeDown(velocity: 2000) }
        let invite = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Invite a friend'")).firstMatch
        scrollTo(invite); if invite.exists { invite.tap(); shot("t14-invite"); app.navigationBars.buttons.element(boundBy: 0).tap() }
        // Start over from the map so the Profile list is in a known state.
        while app.navigationBars.buttons["Done"].exists == false && app.navigationBars.buttons.count > 0 {
            app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)
        }
        if app.navigationBars.buttons["Done"].exists { app.navigationBars.buttons["Done"].tap() }
        XCTAssertTrue(app.buttons["START RUN"].waitForExistence(timeout: 10))
        tap(app.buttons["Profile and settings"])
        let practice = app.buttons["Practice run"]
        scrollTo(practice); tap(practice)
        XCTAssertTrue(app.staticTexts["Practice"].waitForExistence(timeout: 30)); sleep(10); shot("t15-practice")
        XCTAssertTrue(app.staticTexts["You've got it"].waitForExistence(timeout: 60)); shot("t15-practice-done")
        app.buttons["Got it"].tap()
        XCTAssertTrue(app.buttons["START RUN"].waitForExistence(timeout: 10))
        app.buttons["START RUN"].tap()
        tap(app.buttons["Simulated run (demo)"])
        XCTAssertTrue(app.staticTexts["HOLD TO FINISH"].waitForExistence(timeout: 10)); sleep(20); shot("t16-run")
        app.buttons["Pause"].tap(); shot("t16-paused"); app.buttons["Resume"].tap()
        app.staticTexts["HOLD TO FINISH"].press(forDuration: 1.6)
        XCTAssertTrue(app.staticTexts["Coins collected"].waitForExistence(timeout: 60)); sleep(6); shot("t17-summary-1")
        app.swipeUp(velocity: 500); shot("t17-summary-2")
        app.swipeUp(velocity: 500); shot("t17-summary-3")
    }
}
