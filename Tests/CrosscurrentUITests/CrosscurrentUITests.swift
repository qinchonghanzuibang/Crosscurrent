import XCTest

final class CrosscurrentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDenseArchiveNavigatesCoreDestinationsAndReader() {
        let app = launchFixture(state: "dense")
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 8))

        for destination in ["flow", "sources", "people", "topics", "saved", "search"] {
            let row = app.descendants(matching: .any)["sidebar-\(destination)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Missing sidebar destination \(destination)")
            row.click()
        }

        app.descendants(matching: .any)["sidebar-today"].click()
        let firstEvent = app.descendants(matching: .any)["today-event-10000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(firstEvent.waitForExistence(timeout: 5))
        firstEvent.click()
        let reader = app.descendants(matching: .any)["event-section-reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        reader.click()
        XCTAssertTrue(app.buttons["Article actions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Selection actions"].exists)
    }

    @MainActor
    func testEmptyArchiveExplainsHowToStart() {
        let app = launchFixture(state: "empty")
        XCTAssertTrue(app.staticTexts["No Events Yet"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Add a Source"].exists)
        app.descendants(matching: .any)["sidebar-flow"].click()
        XCTAssertTrue(app.staticTexts["No Events in Flow"].waitForExistence(timeout: 5))
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
