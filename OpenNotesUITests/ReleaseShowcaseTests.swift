import XCTest

/// Real app captures with synthetic notebooks; run on a dedicated simulator.
@MainActor
final class ReleaseShowcaseTests: XCTestCase {
    func testPublicPreviewTour() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-fingerDrawing", "YES", "-inkTool", "pen", "-openNotebooks", "()", "-activeNotebook", "", "-toolPaletteVisible", "YES", "-toolPaletteDock", "top", "-defaultPageTemplate", "grid"]
        app.launch()
        defer { app.terminate() }
        if app.buttons["workspace.library"].waitForExistence(timeout: 3) { app.buttons["workspace.library"].tap() }
        for title in ["Reading journal", "Little things to remember", "A weekend in the mountains"] {
            XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 30))
            app.buttons["library.create"].tap()
            let field = app.textFields["library.new.title"]
            XCTAssertTrue(field.waitForExistence(timeout: 15))
            field.tap(); field.typeText(title)
            app.buttons["library.new.confirm"].tap()
            XCTAssertTrue(app.scrollViews["editor.canvas"].waitForExistence(timeout: 30))
            if title != "A weekend in the mountains" { app.buttons["workspace.library"].tap() }
        }
        let canvas = app.scrollViews["editor.canvas"]
        app.buttons["editor.favorite.2"].tap()
        // A small mountain sketch, drawn through the same input path as finger ink.
        for (x1, y1, x2, y2) in [(0.18, 0.55, 0.38, 0.29), (0.38, 0.29, 0.61, 0.55),
                                   (0.48, 0.41, 0.60, 0.26), (0.60, 0.26, 0.82, 0.55),
                                   (0.18, 0.55, 0.82, 0.55), (0.32, 0.37, 0.43, 0.37)] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: x1, dy: y1)).press(forDuration: 0.05,
                thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: x2, dy: y2)))
        }
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        capture(app, "editor")
        app.buttons["editor.tool.pen"].tap()
        XCTAssertTrue(app.buttons["Ballpoint"].waitForExistence(timeout: 15))
        capture(app, "pen-options")
        app.buttons["Done"].tap()
        app.buttons["workspace.library"].tap()
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 30))
        capture(app, "library")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "build36-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
