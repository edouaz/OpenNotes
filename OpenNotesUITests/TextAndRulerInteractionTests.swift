import XCTest

@MainActor
final class TextAndRulerInteractionTests: XCTestCase {
    func testFilledRectangleCanBeEditedDeletedAndRestoredWithUndo() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-nativeTools", "NO", "-showUndo", "YES", "-openNotebooks", "()", "-activeNotebook", ""]
        app.launch()
        defer { app.terminate() }
        if app.buttons["workspace.library"].waitForExistence(timeout: 3) { app.buttons["workspace.library"].tap() }
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 10))
        app.buttons["library.create"].tap(); XCTAssertTrue(app.buttons["library.new.confirm"].waitForExistence(timeout: 5)); app.buttons["library.new.confirm"].tap()
        XCTAssertTrue(app.buttons["editor.actions"].waitForExistence(timeout: 10))
        app.buttons["editor.actions"].tap()
        app.buttons["Shapes"].tap()
        XCTAssertTrue(app.buttons["Rectangle"].waitForExistence(timeout: 5))
        app.buttons["Rectangle"].tap()
        let fill = app.switches["Fill shape"].firstMatch
        XCTAssertTrue(fill.waitForExistence(timeout: 5))
        XCTAssertEqual(fill.value as? String, "0")
        let knob = fill.switches.firstMatch
        if knob.exists { knob.tap() } else { fill.tap() }
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: fill)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 5), .completed)
        app.buttons["editor.shape.save"].tap()
        waitForShapeSheetToClose(app)
        capture(app, "Filled rectangle on page")
        app.buttons["editor.actions"].tap()
        app.buttons["Shapes"].tap()
        XCTAssertTrue(app.buttons["Rectangle 1"].waitForExistence(timeout: 5))
        app.buttons["Rectangle 1"].tap()
        XCTAssertTrue(fill.waitForExistence(timeout: 5))
        XCTAssertEqual(fill.value as? String, "1", "The fill must remain saved after reopening")
        let delete = app.buttons["Delete shape"]
        for _ in 0..<5 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.isHittable)
        delete.tap()
        waitForShapeSheetToClose(app)
        capture(app, "Rectangle deletion")
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); XCTAssertTrue(undo.isEnabled); XCTAssertTrue(undo.isHittable)
        undo.tap()
        app.buttons["editor.actions"].tap()
        app.buttons["Shapes"].tap()
        XCTAssertTrue(app.buttons["Rectangle 1"].waitForExistence(timeout: 5))
        app.buttons["Rectangle 1"].tap()
        XCTAssertTrue(fill.waitForExistence(timeout: 5))
        XCTAssertEqual(fill.value as? String, "1", "Undoing deletion must restore the fill")
        capture(app, "Rectangle restored with its fill")
        app.buttons["Cancel"].firstMatch.tap()
    }

    func testTextCreationEditingAndNativeRulerSurviveRelaunch() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-nativeTools", "NO", "-inkTool", "lasso", "-openNotebooks", "()", "-activeNotebook", ""]
        app.launch()
        app.launchArguments = ["-nativeTools", "NO"]
        defer { app.terminate() }
        if app.buttons["workspace.library"].waitForExistence(timeout: 3) { app.buttons["workspace.library"].tap() }
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 10))
        app.buttons["library.create"].tap(); XCTAssertTrue(app.buttons["library.new.confirm"].waitForExistence(timeout: 5)); app.buttons["library.new.confirm"].tap()
        let ruler = app.buttons["editor.ruler"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        if !ruler.isSelected { ruler.tap() }
        XCTAssertTrue(ruler.isSelected)
        XCTAssertTrue(app.buttons["Pen"].isSelected, "Enabling the ruler from the lasso must return to a writing instrument")
        app.buttons["editor.actions"].tap()
        app.buttons["Text"].tap()
        XCTAssertTrue(app.buttons["Add text"].waitForExistence(timeout: 5))
        app.buttons["Add text"].tap()
        let content = app.textViews["editor.text.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        content.tap(); content.typeText("Persistent text")
        app.buttons["editor.text.save"].tap()
        XCTAssertTrue(ruler.waitForExistence(timeout: 5))
        capture(app, "Text and native ruler on iPad")
        app.terminate(); app.launch()
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        XCTAssertTrue(ruler.isSelected, "The ruler must remain enabled after relaunch")
        app.buttons["editor.actions"].tap()
        app.buttons["Text"].tap()
        app.buttons["Persistent text"].tap()
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertEqual(content.value as? String, "Persistent text")
        content.tap(); content.typeText(" modified")
        app.buttons["editor.text.save"].tap()
        XCTAssertTrue(ruler.waitForExistence(timeout: 5))
        ruler.tap(); XCTAssertFalse(ruler.isSelected)
        capture(app, "Edited text after reopening")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func waitForShapeSheetToClose(_ app: XCUIApplication) {
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["editor.shape.save"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
    }
}
