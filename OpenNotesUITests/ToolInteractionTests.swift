import XCTest

@MainActor
final class ToolInteractionTests: XCTestCase {
    func testDirectToolsAnchoredOptionsEraserSizeAndIntegratedPages() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-nativeTools", "NO", "-inkTool", "pen"]
        app.launch()
        defer { app.terminate() }
        if app.buttons["workspace.library"].waitForExistence(timeout: 5) { app.buttons["workspace.library"].tap() }
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 10))
        app.buttons["library.create"].tap(); XCTAssertTrue(app.buttons["library.new.confirm"].waitForExistence(timeout: 5)); app.buttons["library.new.confirm"].tap()
        XCTAssertTrue(app.scrollViews["editor.canvas"].waitForExistence(timeout: 10))
        for id in ["editor.pages", "editor.search", "editor.export", "editor.tool.pen", "editor.tool.eraser"] {
            XCTAssertTrue(app.buttons[id].isHittable, id)
        }
        app.buttons["editor.tool.pen"].tap()
        XCTAssertTrue(app.navigationBars["Instrument"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Stabilization"].exists)
        screenshot(app, "Options below the active pen")
        app.buttons["Done"].tap()
        app.buttons["editor.tool.eraser"].tap()
        XCTAssertFalse(app.navigationBars["Instrument"].exists, "First tap selects; second opens options")
        app.buttons["editor.tool.eraser"].tap()
        XCTAssertTrue(app.navigationBars["Instrument"].waitForExistence(timeout: 5))
        for mode in ["Stroke", "Standard", "Precision"] {
            let button = app.buttons[mode]
            XCTAssertTrue(button.isHittable, mode)
            button.tap()
            XCTAssertTrue(button.isSelected, mode)
        }
        screenshot(app, "Precision eraser options")
        app.buttons["Done"].tap()
        let preset = app.buttons["editor.width.2"]
        preset.tap()
        if !app.sliders["Thickness"].waitForExistence(timeout: 1) { preset.tap() }
        let size = app.sliders["Thickness"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        size.adjust(toNormalizedSliderPosition: 0.42)
        XCTAssertTrue(size.isHittable)
        screenshot(app, "Eraser size preset")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        let canvas = app.scrollViews["editor.canvas"]
        let before = canvas.exists ? canvas.frame : app.otherElements["editor.canvas"].frame
        app.buttons["editor.pages"].tap()
        XCTAssertTrue(app.buttons["editor.pages.close"].waitForExistence(timeout: 5))
        let after = canvas.exists ? canvas.frame : app.otherElements["editor.canvas"].frame
        if app.frame.width >= 700 {
            XCTAssertLessThan(after.width, before.width)
            XCTAssertGreaterThan(after.width, 200)
        }
        screenshot(app, "Previews in the integrated panel")
        app.buttons["editor.pages.close"].tap()
        XCTAssertFalse(app.buttons["editor.pages.close"].exists)
    }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
