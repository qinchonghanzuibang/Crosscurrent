import XCTest

final class CrosscurrentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDenseArchiveNavigatesCoreDestinationsAndReader() {
        let app = launchFixture(state: "dense")
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 8))

        for destination in ["flow", "following", "saved", "search"] {
            let row = app.descendants(matching: .any)["sidebar-\(destination)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Missing sidebar destination \(destination)")
            row.click()
        }

        app.descendants(matching: .any)["sidebar-flow"].click()
        let firstEvent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "flow-event-")).firstMatch
        XCTAssertTrue(firstEvent.waitForExistence(timeout: 5))
        firstEvent.click()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Back"].exists)
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["Exit Focus Reading"].waitForExistence(timeout: 3))
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.buttons["Back"].click()
        XCTAssertTrue(firstEvent.waitForExistence(timeout: 3))
    }

    @MainActor
    func testEmptyArchiveExplainsHowToStart() {
        let app = launchFixture(state: "empty")
        XCTAssertTrue(app.staticTexts["No Events Yet"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Add a Source"].exists)
        app.buttons["Add a Source"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["Official Account name or Source URL"].exists)
        app.buttons["Cancel"].click()
        app.descendants(matching: .any)["sidebar-flow"].click()
        XCTAssertTrue(app.staticTexts["No Events in Flow"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
    }

    @MainActor
    private func launchFixture(state: String) -> XCUIApplication {
        let app = XCUIApplication()
        let container = NSTemporaryDirectory() + "Crosscurrent-UITests-\(UUID().uuidString)"
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--fixture-container", container,
            "--fixture-state", state,
            "--fixture-appearance", "light",
        ]
        app.launch()
        return app
    }
}
