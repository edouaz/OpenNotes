import XCTest

@MainActor
final class NativeInkInteractionUITests: XCTestCase {
    func testFingerInkUndoRedoAndReopen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-fingerDrawing", "YES", "-inkTool", "pen", "-openNotebooks", "()", "-activeNotebook", ""]
        app.launch()
        defer { app.terminate() }
        if app.buttons["workspace.library"].waitForExistence(timeout: 3) { app.buttons["workspace.library"].tap() }
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 10))
        app.buttons["library.create"].tap(); XCTAssertTrue(app.buttons["library.new.confirm"].waitForExistence(timeout: 5)); app.buttons["library.new.confirm"].tap()
        let canvas = app.scrollViews["editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.tab.")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        let notebookID = String(tab.identifier.dropFirst("workspace.tab.".count))

        let undo = app.buttons["Undo"], redo = app.buttons["Redo"]
        XCTAssertFalse(undo.isEnabled)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.6)))
        waitEnabled(undo)
        capture(app, "Native UIView ink — actual finger stroke")
        undo.tap(); waitEnabled(redo)
        XCTAssertFalse(undo.isEnabled)
        redo.tap(); waitEnabled(undo)
        XCTAssertFalse(redo.isEnabled)
        capture(app, "Native UIView ink — redo restored")

        app.buttons["editor.tool.pen"].tap()
        XCTAssertTrue(app.sliders["Stabilization"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Ballpoint"].exists)
        capture(app, "Native pen options — type and stabilization")
        app.buttons["Done"].tap()

        let preset = app.buttons["editor.width.2"]
        preset.tap()
        if !app.sliders["Thickness"].waitForExistence(timeout: 1) { preset.tap() }
        XCTAssertTrue(app.sliders["Thickness"].waitForExistence(timeout: 5))
        let pattern = app.buttons["editor.pattern.dashed"]
        XCTAssertTrue(pattern.isHittable, "Patterns must be reachable from a stroke preset")
        pattern.tap()
        XCTAssertTrue(pattern.isSelected)
        capture(app, "Native stroke preset — pattern and thickness")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()

        app.buttons["workspace.library"].tap()
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        let notebook = app.buttons["library.note." + notebookID]
        XCTAssertTrue(notebook.waitForExistence(timeout: 10)); notebook.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertFalse(undo.isEnabled, "Reopening resets editing history")
        capture(app, "Native ink — persisted page after process relaunch")
    }
    private func waitEnabled(_ button: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
