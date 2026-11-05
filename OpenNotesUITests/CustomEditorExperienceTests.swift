import XCTest

@MainActor
final class CustomEditorExperienceTests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        // An old install may still have the native-palette preference enabled.
        app.launchArguments = ["-nativeTools", "YES", "-inkTool", "pen", "-fingerDrawing", name.contains("testNativeWritingUndoAndRedo") ? "YES" : "NO",
                               "-showUndo", "YES", "-showInkColor", "YES", "-showInkWidth", "YES",
                               "-openNotebooks", "()", "-activeNotebook", ""]
        app.launch()
        if app.buttons["workspace.library"].waitForExistence(timeout: 3) { app.buttons["workspace.library"].tap() }
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 10)); app.buttons["library.create"].tap(); XCTAssertTrue(app.buttons["library.new.confirm"].waitForExistence(timeout: 5)); app.buttons["library.new.confirm"].tap()
        XCTAssertTrue(app.buttons["editor.pages"].waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "Custom editor hierarchy"; tree.lifetime = .keepAlways; add(tree)
            capture("Custom editor — failure")
        }
        app.terminate()
    }
    func testEssentialToolsAndNotebookRoundTrip() {
        let title = "Simple notes " + UUID().uuidString.prefix(8)
        app.buttons["editor.actions"].tap()
        app.buttons["Rename notebook"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let oldTitle = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldTitle.count) + title)
        app.alerts.buttons["Save"].tap()
        for tool in ["pen", "marker", "eraser", "lasso"] {
            let button = app.buttons["editor.tool.\(tool)"]
            XCTAssertTrue(button.isHittable)
            button.tap()
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            XCTAssertTrue(button.isSelected)
        }
        app.buttons["editor.tool.pen"].tap()
        app.buttons["editor.tool.pen"].tap()
        XCTAssertTrue(app.navigationBars["Instrument"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        let preset = app.buttons["editor.width.2"]
        preset.tap()
        if !app.sliders["Thickness"].waitForExistence(timeout: 1) { preset.tap() }
        let width = app.sliders["Thickness"]
        XCTAssertTrue(width.isHittable)
        width.adjust(toNormalizedSliderPosition: 0.75)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        let canvas = app.scrollViews["editor.canvas"]
        XCTAssertGreaterThan(canvas.frame.height, app.frame.height * 0.5)
        app.buttons["editor.addPage"].tap()
        let pages = app.buttons["editor.pages"]
        let added = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Page 2 of 2"), object: pages)
        XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 10), .completed)
        capture("Simple writing workspace")
        app.buttons["workspace.library"].tap()
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 10))
        let notebook = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "library.note.", title)).firstMatch
        XCTAssertTrue(notebook.waitForExistence(timeout: 5))
        notebook.tap()
        XCTAssertTrue(pages.waitForExistence(timeout: 10))
        XCTAssertEqual(pages.value as? String, "Page 2 of 2")
    }
    func testNativeWritingUndoAndRedo() {
        // Set the input policy at launch: launch arguments override persisted defaults,
        // so toggling AppStorage while -fingerDrawing NO is active cannot enable input.
        let canvas = app.scrollViews["editor.canvas"]
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        let undo = app.buttons["Undo"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: undo)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        undo.tap()
        let redo = app.buttons["Redo"]
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        XCTAssertTrue(undo.isEnabled)
        capture("Native stroke after undo and redo")
    }

    func testDoubleTapFromManualZoomFitsWidthThenHeight() {
        let canvas = app.scrollViews["editor.canvas"]
        let frame = canvas.frame
        let full = max(0.1, min(4, (frame.width - 32) / 794, (frame.height - 32) / 1123))
        let widthPercent = Int((((frame.width - 32) / 794) / full * 100).rounded())
        let heightPercent = Int((((frame.height - 32) / 1123) / full * 100).rounded())
        canvas.pinch(withScale: 2.4, velocity: 2)
        canvas.doubleTap()
        expectZoom(canvas, percent: widthPercent)
        capture("Double tap — fit width after free zoom")
        canvas.doubleTap()
        expectZoom(canvas, percent: heightPercent)
        capture("Double tap — fit height")
    }
    private func expectZoom(_ canvas: XCUIElement, percent: Int) {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = (canvas.value as? String ?? "").split(separator: " ").compactMap { Int($0) }.first ?? -1
            return abs(current - percent) <= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
