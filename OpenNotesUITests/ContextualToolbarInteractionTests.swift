import XCTest

@MainActor
final class ContextualToolbarInteractionTests: XCTestCase {
    func testUnifiedToolbarAndScreenshot() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-nativeTools", "NO", "-inkTool", "pen", "-showUndo", "YES",
                               "-undoPlacement", "left", "-editorToolSettings", "", "-instrumentPresets", "", "-inkWidth", "3",
                               "-favoriteInkColors", "#202725,#B34242,#315BB1",
                               "-openNotebooks", "()", "-activeNotebook", ""]
        app.launch()
        defer { app.terminate() }
        if app.buttons["workspace.library"].waitForExistence(timeout: 5) { app.buttons["workspace.library"].tap() }
        let create = app.buttons["library.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.tap()
        XCTAssertTrue(app.buttons["library.new.confirm"].waitForExistence(timeout: 5)); app.buttons["library.new.confirm"].tap()
        let canvas = app.scrollViews["editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        let toolbar = app.scrollViews["editor.toolbar.scroll"]
        let pen = app.buttons["editor.tool.pen"]
        let favorite = app.buttons["editor.favorite.0"]
        let width = app.buttons["editor.width.3"]
        let undo = app.buttons["Undo"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        XCTAssertTrue(favorite.exists)
        XCTAssertEqual(pen.frame.midY, favorite.frame.midY, accuracy: 2)
        XCTAssertEqual(pen.frame.midY, width.frame.midY, accuracy: 2)
        let undoFrame = undo.frame
        for _ in 0..<3 where !width.isHittable { toolbar.swipeLeft() }
        XCTAssertTrue(width.isHittable)
        XCTAssertEqual(undo.frame, undoFrame, "Undo stays pinned while tools scroll")
        XCTAssertFalse(width.isSelected)
        width.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        XCTAssertTrue(width.isSelected, "The full width preset target responds")
        XCTAssertFalse(app.sliders["Thickness"].exists)
        width.tap()
        XCTAssertTrue(app.sliders["Thickness"].waitForExistence(timeout: 5))
        let dashed = app.buttons["editor.pattern.dashed"]
        XCTAssertTrue(dashed.exists)
        dashed.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        XCTAssertTrue(dashed.isSelected, "The full pattern target responds")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Stroke preset anchored below toolbar"; attachment.lifetime = .keepAlways
        add(attachment)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()

        for _ in 0..<4 where !favorite.isHittable { toolbar.swipeLeft() }
        if favorite.isSelected { app.buttons["editor.favorite.1"].tap() }
        favorite.tap()
        XCTAssertFalse(app.segmentedControls["editor.colorSource"].exists)
        favorite.tap()
        let sources = app.segmentedControls["editor.colorSource"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.buttons["History"].tap()
        XCTAssertTrue(app.buttons["#202725"].exists)
        sources.buttons["Custom"].tap()
        XCTAssertTrue(app.buttons["Use color"].exists)
        app.buttons["Cancel"].tap()
        let addColor = app.buttons["Add favorite color"]
        for _ in 0..<4 where !addColor.isHittable { toolbar.swipeLeft() }
        addColor.tap()
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["editor.favorite.3"].exists, "Cancel must not add a favorite")
        addColor.tap()
        app.buttons["#E59E32"].tap()
        XCTAssertTrue(app.buttons["editor.favorite.3"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor.favorite.3"].isSelected)
        let marker = app.buttons["editor.tool.marker"]
        for _ in 0..<4 where !marker.isHittable { toolbar.swipeRight() }
        marker.tap()
        for _ in 0..<4 where !app.buttons["editor.favorite.0"].isHittable { toolbar.swipeLeft() }
        XCTAssertEqual(app.buttons["editor.favorite.0"].label, "Favorite color #FFE66D")
        XCTAssertFalse(app.buttons["editor.favorite.3"].exists)
        for _ in 0..<4 where !pen.isHittable { toolbar.swipeRight() }
        pen.tap()
        for _ in 0..<4 where !app.buttons["editor.favorite.3"].isHittable { toolbar.swipeLeft() }
        XCTAssertTrue(app.buttons["editor.favorite.3"].exists, "Pen favorites survive instrument changes")

        for _ in 0..<3 where !app.buttons["editor.tool.lasso"].isHittable { toolbar.swipeRight() }
        let lasso = app.buttons["editor.tool.lasso"]
        XCTAssertTrue(lasso.isHittable); lasso.tap(); lasso.tap()
        let handles = app.switches["Enable resizing"]
        XCTAssertTrue(handles.waitForExistence(timeout: 5))
        let before = handles.value as? String
        handles.tap()
        XCTAssertNotEqual(handles.value as? String, before)
        app.buttons["Done"].tap()

        let layout = app.buttons["editor.toolbarLayout"]
        for _ in 0..<4 where !layout.isHittable { toolbar.swipeLeft() }
        layout.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        app.buttons["Customize toolbar"].tap()
        XCTAssertFalse(app.switches["Tool options"].exists)
        let lassoToggle = app.switches["Lasso"]
        XCTAssertTrue(lassoToggle.waitForExistence(timeout: 5))
        lassoToggle.tap()
        app.buttons["Done"].tap()
        XCTAssertFalse(lasso.exists)
        layout.tap(); app.buttons["Customize toolbar"].tap(); app.switches["Lasso"].tap(); app.buttons["Done"].tap()

        app.buttons["editor.actions"].tap()
        let screenshot = app.buttons["editor.quickScreenshotCopy"]
        XCTAssertTrue(screenshot.waitForExistence(timeout: 5)); screenshot.tap()
        XCTAssertTrue(app.staticTexts["Screenshot copied"].waitForExistence(timeout: 5))
        XCTAssertTrue(canvas.exists, "The screenshot action keeps the editor open")

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let highlighter = app.buttons["editor.tool.marker"]
        for _ in 0..<3 where !highlighter.isHittable { toolbar.swipeRight() }
        highlighter.tap(); highlighter.tap()
        XCTAssertTrue(app.sliders["Stabilization"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Ballpoint"].exists)
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Highlighter stabilization anchored in landscape"; landscape.lifetime = .keepAlways
        add(landscape)
        app.buttons["Done"].tap()
    }
}
