import AppKit
import XCTest

final class CrosscurrentUITests: XCTestCase {
    private var fixtureContainers: [URL] = []

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        for container in fixtureContainers where FileManager.default.fileExists(atPath: container.path) {
            try FileManager.default.removeItem(at: container)
        }
        fixtureContainers = []
    }

    @MainActor
    func testDenseArchiveNavigatesCoreDestinationsAndReader() {
        let app = launchFixture(state: "dense")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 8))

        for destination in ["flow", "following", "saved", "search"] {
            let row = app.descendants(matching: .any)["sidebar-\(destination)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Missing sidebar destination \(destination)")
            row.click()
        }

        app.descendants(matching: .any)["sidebar-flow"].click()
        app.radioButtons["Chronological"].click()
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
        XCTAssertEqual((app.radioButtons["Chronological"].value as? NSNumber)?.intValue, 1)
    }

    @MainActor
    func testSearchKeepsQueryAndScopeWhenReturningFromDetails() {
        let app = launchFixture(state: "dense")
        defer { app.terminate() }
        let destination = app.descendants(matching: .any)["sidebar-search"]
        XCTAssertTrue(destination.waitForExistence(timeout: 8))
        destination.click()
        let query = app.textFields["Search"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        query.click()
        pasteLiteral("model", into: query)
        XCTAssertEqual(query.value as? String, "model")
        app.radioButtons["Events"].click()
        app.checkBoxes["History"].click()
        let story = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-result-event-")).firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 5))
        story.click()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        XCTAssertEqual(query.value as? String, "model")
        XCTAssertEqual((app.radioButtons["Events"].value as? NSNumber)?.intValue, 1)
        XCTAssertEqual((app.checkBoxes["History"].value as? NSNumber)?.intValue, 1)

        app.radioButtons["Sources"].click()
        let source = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "search-result-source-")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 3))
        app.buttons["Back"].click()
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        XCTAssertEqual(query.value as? String, "model")
        XCTAssertEqual((app.radioButtons["Sources"].value as? NSNumber)?.intValue, 1)
    }

    @MainActor
    func testEmptyArchiveExplainsHowToStart() {
        let app = launchFixture(state: "empty")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Your briefing starts here"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Add a Source"].exists)
        app.buttons["Add a Source"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields.firstMatch.exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(app.sheets.firstMatch.exists)
        app.descendants(matching: .any)["sidebar-flow"].click()
        XCTAssertTrue(app.staticTexts["No stories yet"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        app.buttons["Cancel"].click()
    }

    @MainActor
    private func pasteLiteral(_ text: String, into field: XCUIElement) {
        // Keyboard synthesis depends on the user's active IME. Paste literal search text
        // without changing their input source, and restore every clipboard representation.
        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(previous)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        field.typeKey("v", modifierFlags: .command)
    }

    @MainActor
    private func launchFixture(state: String) -> XCUIApplication {
        let app = XCUIApplication()
        let container = NSTemporaryDirectory() + "Crosscurrent-UITests-\(UUID().uuidString)"
        fixtureContainers.append(URL(fileURLWithPath: container, isDirectory: true))
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
