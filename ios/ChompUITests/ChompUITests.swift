import XCTest

/// Walks every screen of the app in demo mode (no account, simulated runs).
final class ChompUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-demo"]
    }

    private func waitForMap() {
        XCTAssertTrue(app.buttons["START RUN"].waitForExistence(timeout: 30), "map screen")
    }

    private func done() {
        let b = app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        b.tap()
    }

    /// Scrolls until the element is on screen.
    @discardableResult
    private func reveal(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        for _ in 0..<8 where !(e.exists && e.frame.minY > 0 && e.frame.maxY < app.frame.maxY - 40) { app.swipeUp() }
        XCTAssertTrue(e.exists, "\(e) not found", file: file, line: line)
        return e
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func test1_IntroCards() {
        app.launchArguments = ["-demo", "-intro"]
        app.launch()
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 15))
        shot("intro-1")
        var cards = 1
        while app.buttons["Next"].exists && cards < 12 {
            app.buttons["Next"].tap()
            cards += 1
            if cards == 2 { sleep(2); shot("intro-capture") }
        }
        XCTAssertEqual(cards, 6, "six intro cards")
        shot("intro-last")
        XCTAssertTrue(app.buttons["Let's play"].waitForExistence(timeout: 5))
        app.buttons["Let's play"].tap()
        waitForMap()
    }

    func test2_SheetsFromTheMap() {
        app.launch()
        waitForMap()
        shot("map")

        app.buttons["Leaderboards"].tap()
        XCTAssertTrue(app.navigationBars["Leaderboards"].waitForExistence(timeout: 5))
        shot("leaderboards")
        done()

        app.buttons["Activity"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        done()

        app.buttons["Coins nearby"].tap()
        XCTAssertTrue(app.navigationBars["Coins near you"].waitForExistence(timeout: 5))
        for f in ["Mine", "Rivals", "To grab"] {
            app.segmentedControls.buttons[f].tap()
        }
        XCTAssertFalse(app.segmentedControls.buttons["Fading"].exists, "streets don't fade any more")
        shot("streets")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS ' away'")).firstMatch.waitForExistence(timeout: 5),
                      "streets show how far away they are")
        done()

        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Run streak'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(app.staticTexts["THIS WEEK'S GOALS"].waitForExistence(timeout: 5) || app.staticTexts["This week's goals"].exists)
        shot("goals")
        done()
    }

    func test3_RoutePlanner() {
        app.launch()
        waitForMap()
        app.buttons["Plan a route"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Plan a route"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save fading"].exists)
        app.buttons["Explore"].tap()
        app.buttons["Grab coins"].tap()
        app.collectionViews.buttons["Plan a route"].tap()
        let show = app.buttons["Show it on the map"]
        XCTAssertTrue(show.waitForExistence(timeout: 30), "a route was planned")
        XCTAssertTrue(app.staticTexts["Coins to collect"].exists)
        app.buttons["Try another"].tap()
        XCTAssertTrue(show.waitForExistence(timeout: 30))
        shot("route-planned")
        show.tap()
        let bar = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Route ·'")).firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "route bar on the map")
        shot("route-on-map")
        app.buttons["Clear planned route"].tap()
        XCTAssertFalse(bar.waitForExistence(timeout: 2))
    }

    func test4_ProfileAndSettings() {
        app.launch()
        waitForMap()
        app.buttons["Profile and settings"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Coins collected"].exists)
        shot("profile")

        // Import a run: opens from the profile, stays open, and shows the file picker.
        reveal(app.buttons["profileImportRun"]).tap()
        XCTAssertTrue(app.navigationBars["Import a run"].waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertTrue(app.navigationBars["Import a run"].exists, "import screen stays open")
        app.buttons["Garmin Connect"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'connect.garmin.com'")).firstMatch.waitForExistence(timeout: 3))
        shot("import-run")
        app.buttons["chooseRunFile"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "file picker opens")
        shot("import-picker")
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Import a run"].waitForExistence(timeout: 5), "back on the import screen after cancelling")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        reveal(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Invite a friend'")).firstMatch).tap()
        XCTAssertTrue(app.navigationBars["Invite friends"].waitForExistence(timeout: 5))
        shot("invite")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        reveal(app.buttons["How Chomp works"]).tap()
        XCTAssertTrue(app.buttons["Skip"].waitForExistence(timeout: 5))
        app.buttons["Skip"].tap()

        reveal(app.buttons["Settings"]).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        for look in ["Light", "Dark", "Dusk"] { app.segmentedControls.buttons[look].tap() }
        let voice = reveal(app.switches["Spoken updates"])
        let wasOn = (voice.value as? String) == "1"
        voice.switches.firstMatch.tap()
        XCTAssertNotEqual((voice.value as? String) == "1", wasOn)
        shot("settings")
        if (voice.value as? String) == "1" { voice.switches.firstMatch.tap() }

        reveal(app.buttons["importRunFile"]).tap()
        XCTAssertTrue(app.navigationBars["Import a run"].waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertTrue(app.navigationBars["Import a run"].exists, "import screen stays open from Settings too")
    }

    func test5_SimulatedRunToSummary() {
        app.launch()
        waitForMap()
        app.buttons["START RUN"].tap()
        let sim = app.buttons["Simulated run (demo)"]
        XCTAssertTrue(sim.waitForExistence(timeout: 5))
        sim.tap()
        let finish = app.otherElements["Finish run"].exists ? app.otherElements["Finish run"] : app.buttons["Finish run"]
        XCTAssertTrue(app.staticTexts["HOLD TO FINISH"].waitForExistence(timeout: 10), "run HUD")
        app.buttons["Turn on spoken updates"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Turn off spoken updates"].waitForExistence(timeout: 3))
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 3))
        app.buttons["Resume"].tap()
        sleep(25)  // let it eat some streets
        shot("run-hud")
        XCTAssertTrue(app.staticTexts["Coins"].exists)
        app.buttons["Turn off spoken updates"].firstMatch.tap()
        _ = finish
        app.staticTexts["HOLD TO FINISH"].press(forDuration: 1.6)
        XCTAssertTrue(app.staticTexts["Coins collected"].waitForExistence(timeout: 60), "run summary")
        XCTAssertTrue(app.staticTexts["THIS WEEK"].exists)
        shot("summary")
        app.swipeUp()
        shot("summary-lower")
        done()
        waitForMap()
    }

    func test6_PracticeRunChangesNothing() {
        app.launch()
        waitForMap()
        app.buttons["Profile and settings"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5))
        reveal(app.buttons["Practice run"]).tap()
        XCTAssertTrue(app.staticTexts["Practice"].waitForExistence(timeout: 30), "practice chip in the HUD")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Nothing counts'")).firstMatch.waitForExistence(timeout: 5),
                      "first coaching tip")
        XCTAssertTrue(app.staticTexts["You've got it"].waitForExistence(timeout: 70), "practice result after 45 s")
        XCTAssertFalse(app.staticTexts["Coins collected"].exists, "no run summary: nothing was saved")
        app.buttons["Got it"].tap()
        waitForMap()
    }
}
