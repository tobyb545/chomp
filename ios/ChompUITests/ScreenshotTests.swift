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
        app.launchArguments = ["-demo", "-marketing"]
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
        let loading = app.staticTexts["Loading the streets around you…"]
        let noTokens = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '· 0 tokens'")).firstMatch
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
        app.buttons["Grab streets"].tap()
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
        XCTAssertTrue(app.staticTexts["Tokens eaten"].waitForExistence(timeout: 60))
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
        let loading = app.staticTexts["Loading the streets around you…"]
        let noTokens = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '· 0 tokens'")).firstMatch
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
        XCTAssertTrue(app.staticTexts["Tokens eaten"].waitForExistence(timeout: 60))
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
}
