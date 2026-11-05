import XCTest
import UIKit

@MainActor
final class CanvasInteractionUITests: XCTestCase {
    private let app = XCUIApplication()
    private var canvas: XCUIElement { app.descendants(matching: .any).matching(identifier: "editor.canvas").firstMatch }
    private var insertedImage: XCUIElement { app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'image.' AND label == 'Image'")).firstMatch }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-nativeTools", "NO", "-inkTool", "pen", "-fingerDrawing", "NO",
                               "-openNotebooks", "()", "-activeNotebook", "", "-verticalPaging", "NO"]
        app.launch()
        if app.buttons["workspace.library"].waitForExistence(timeout: 5) { app.buttons["workspace.library"].tap() }
        XCTAssertTrue(app.buttons["library.create"].waitForExistence(timeout: 10))
        app.buttons["library.create"].tap(); XCTAssertTrue(app.buttons["library.new.confirm"].waitForExistence(timeout: 5)); app.buttons["library.new.confirm"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            screenshot("Canvas — failure")
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "Canvas — hierarchy"; tree.lifetime = .keepAlways; add(tree)
        }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }
    func testCapturedImageFreeTapReselectFingerDragAndDelete() {
        insertCapture()
        screenshot("Inserted image — outline and handles")
        deselectImage()
        XCTAssertFalse(app.buttons["editor.mode.done"].exists)
        selectInsertedImage()
        moveImage()
        screenshot("Image — finger drag after reselection")
        let frame = insertedImage.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 44, dy: frame.minY - 22)).tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: insertedImage)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        screenshot("Image — deletion from corner control")
    }
    func testImageHandlesAfterPinchAndRotation() {
        insertCapture(); deselectImage()
        canvas.pinch(withScale: 2, velocity: 1)
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = (self.canvas.value as? String ?? "").split(separator: " ").compactMap { Int($0) }.first ?? 0
            return value > 120
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
        let beforePan = insertedImage.frame
        let pan = insertedImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        pan.press(forDuration: 0.05, thenDragTo: pan.withOffset(CGVector(dx: 0, dy: -80)))
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.insertedImage.frame.minY < beforePan.minY - 30
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 5), .completed, "One finger scrolls over an idle image in Pencil-only mode")
        XCTAssertNotEqual(insertedImage.value as? String, "Selected")
        selectInsertedImage()
        let before = insertedImage.frame
        let right = point(CGPoint(x: before.maxX, y: before.midY))
        right.press(forDuration: 0.05, thenDragTo: right.withOffset(CGVector(dx: 25, dy: 0)))
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.insertedImage.frame.width > before.width + 10 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 5), .completed)
        XCTAssertEqual(insertedImage.frame.height, before.height, accuracy: 2)
        let side = insertedImage.frame
        let corner = point(CGPoint(x: side.minX, y: side.maxY))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: -15, dy: 15)))
        XCTAssertEqual(insertedImage.frame.width / insertedImage.frame.height, side.width / side.height, accuracy: 0.02)
        screenshot("Image — side and corner handles while zoomed")
        XCUIDevice.shared.orientation = .landscapeLeft
        canvas.doubleTap()
        selectInsertedImage()
        XCTAssertEqual(insertedImage.value as? String, "Selected")
        moveImage()
        screenshot("Image — selection and dragging after rotation")
    }
    private func point(_ point: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
    }
    private func insertCapture() {
        app.buttons["editor.actions"].tap()
        let capture = app.buttons["Capture entire page"]
        for _ in 0..<5 where !capture.isHittable { app.swipeUp() }
        XCTAssertTrue(capture.isHittable); capture.tap()
        XCTAssertTrue(app.buttons["capture.insert"].waitForExistence(timeout: 10))
        app.buttons["capture.insert"].tap()
        XCTAssertTrue(insertedImage.waitForExistence(timeout: 10))
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: insertedImage)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
    }
    private func deselectImage() {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.12)).tap()
        let deselected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "Selected"), object: insertedImage)
        XCTAssertEqual(XCTWaiter.wait(for: [deselected], timeout: 5), .completed)
    }
    private func selectInsertedImage() {
        insertedImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: insertedImage)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }
    private func moveImage() {
        let before = insertedImage.frame
        let start = insertedImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 35, dy: 25)))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(self.insertedImage.frame.minX - before.minX) > 15 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
    }
    func testStickyNoteHandwritingFirstAndExplicitText() {
        let direct = app.buttons["editor.tool.stickyNote"]
        XCTAssertTrue(direct.waitForExistence(timeout: 5))
        direct.tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let addText = app.buttons["Add text to sticky note"]
        XCTAssertTrue(addText.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        screenshot("Sticky note — handwriting-first controls")
        addText.tap()
        let text = app.textViews["Sticky note text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.typeText("Text preserved after collapse")
        app.toolbars.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Collapse sticky note"].waitForExistence(timeout: 5))
        app.buttons["Collapse sticky note"].tap()
        XCTAssertTrue(app.buttons["Expand sticky note"].waitForExistence(timeout: 5))
        app.buttons["Expand sticky note"].tap()
        let edit = app.buttons["Edit sticky note text"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, "Text preserved after collapse")
        screenshot("Sticky note — explicit text editing")
    }
    func testStickySelectMoveResizeCollapseAndCustomize() {
        app.buttons["editor.tool.stickyNote"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.35)).tap()
        let sticky = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sticky.'")).firstMatch
        XCTAssertTrue(sticky.waitForExistence(timeout: 5))
        let before = sticky.frame
        let center = sticky.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 30, dy: 30)))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in sticky.frame.minX > before.minX + 15 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        let handle = app.descendants(matching: .any)["Resize sticky note"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let width = sticky.frame.width
        let corner = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: 35, dy: 25)))
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in sticky.frame.width > width + 15 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 5), .completed)
        app.buttons["Collapse sticky note"].tap()
        let collapsed = app.buttons["Expand sticky note"]
        XCTAssertTrue(collapsed.waitForExistence(timeout: 5))
        let closedOrigin = collapsed.frame.origin
        let closed = collapsed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        closed.press(forDuration: 0.7, thenDragTo: closed.withOffset(CGVector(dx: 30, dy: 30)))
        let closedMoved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in collapsed.exists && collapsed.frame.minX > closedOrigin.x + 15 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closedMoved], timeout: 5), .completed)
        collapsed.tap()
        XCTAssertTrue(app.buttons["Sticky note actions"].waitForExistence(timeout: 5))
        app.buttons["Sticky note actions"].tap()
        app.buttons["Customize…"].tap()
        XCTAssertTrue(app.navigationBars["Sticky note"].waitForExistence(timeout: 5))
        app.buttons["Card"].tap()
        screenshot("Sticky note — card appearance")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Sticky note actions"].waitForExistence(timeout: 5))
        app.buttons["Sticky note actions"].tap()
        app.buttons["Duplicate"].tap()
        let duplicated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sticky.'")).count == 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [duplicated], timeout: 5), .completed)
        screenshot("Sticky notes — duplicate card")
    }
    func testPinchStartingOnStickyZoomsCanvasWithoutObjectEdit() {
        app.buttons["editor.tool.stickyNote"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.35)).tap()
        let sticky = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sticky.'")).firstMatch
        XCTAssertTrue(sticky.waitForExistence(timeout: 5))
        sticky.pinch(withScale: 1.5, velocity: 1)
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = (self.canvas.value as? String ?? "").split(separator: " ").compactMap { Int($0) }.first ?? 0
            return value > 120
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        screenshot("Sticky note — two-finger canvas zoom")
        app.buttons["Undo"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sticky)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed, "Navigation must not add an object-edit undo step")
    }
    private func screenshot(_ name: String) {
        let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.name = name; evidence.lifetime = .keepAlways; add(evidence)
    }
}
