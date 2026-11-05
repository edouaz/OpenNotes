import XCTest
import UIKit.UIGestureRecognizerSubclass
@testable import OpenNotes

private final class StickyTestTouch: UITouch {
    var point = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
}

private final class StickyTestPan: StickyDragPan {
    var simulatedState: UIGestureRecognizer.State = .possible
    var point = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { simulatedState }
        set { simulatedState = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
final class StickyManipulationTests: XCTestCase {
    func testSelectionControlsAndBodyHitTesting() {
        let control = StickyNoteControl(item: PageElement(kind: .stickyNote, x: 20, y: 20, width: 180, height: 160))
        control.frame = CGRect(x: 0, y: 0, width: 180, height: 160)
        control.layoutIfNeeded()
        XCTAssertTrue(control.resizeHandle.isHidden)
        XCTAssertTrue(control.textButton.isHidden)
        XCTAssertFalse(control.isAccessibilityElement)
        let body = control.accessibilityElements?.first as? UIAccessibilityElement
        XCTAssertTrue(body?.accessibilityActivate() == true)
        // Selected notes stay visually quiet: four corner handles, no per-note buttons.
        XCTAssertTrue(control.textButton.isHidden && control.dragHandle.isHidden)
        XCTAssertFalse(control.collapseButton.isHidden, "Header chevron collapses in one tap")
        XCTAssertFalse(control.deleteButton.isHidden, "Selected notes show the red delete cross")
        XCTAssertEqual(control.cornerHandles.count, 3)
        XCTAssertTrue(control.allResizeHandles.allSatisfy { !$0.isHidden })
        control.setObjectSelected(false)
        control.allowsBodySelection = false
        XCTAssertNil(control.hitTest(CGPoint(x: 90, y: 80), with: nil))
        control.setObjectSelected(true)
        XCTAssertFalse(control.resizeHandle.isHidden)
        XCTAssertTrue(control.hitTest(CGPoint(x: 90, y: 80), with: nil) === control)
        control.setObjectSelected(false)
        XCTAssertTrue(control.resizeHandle.isHidden)
    }

    func testManipulationRecognizersAcceptOnlyOneDirectTouch() {
        let control = StickyNoteControl(item: PageElement(kind: .stickyNote))
        let gestures = ((control.gestureRecognizers ?? []) + (control.resizeHandle.gestureRecognizers ?? []) + (control.dragHandle.gestureRecognizers ?? [])).filter { $0.delegate === control }
        XCTAssertFalse(gestures.isEmpty)
        for gesture in gestures {
            XCTAssertEqual(gesture.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
            if let pan = gesture as? UIPanGestureRecognizer { XCTAssertEqual(pan.maximumNumberOfTouches, 1) }
        }
    }

    func testNavigationTracksOnlyNoteSequencesAndAlwaysRestores() {
        let recognizer = StickyNavigationPan(target: nil, action: nil)
        let note = StickyNoteControl(item: PageElement(kind: .stickyNote))
        var tracking: [Bool] = []
        var secondTouches = 0
        recognizer.trackingChanged = { tracking.append($0) }
        recognizer.additionalTouch = { secondTouches += 1 }
        XCTAssertEqual(recognizer.minimumNumberOfTouches, 2)
        XCTAssertEqual(recognizer.maximumNumberOfTouches, 2)
        XCTAssertEqual(recognizer.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.direct.rawValue)])
        XCTAssertFalse(recognizer.observeTouchBegin(firstView: UIView(), count: 1))
        recognizer.reset()
        XCTAssertTrue(tracking.isEmpty)
        XCTAssertTrue(recognizer.observeTouchBegin(firstView: note.textButton, count: 1))
        XCTAssertTrue(recognizer.note === note)
        XCTAssertEqual(tracking, [true])
        recognizer.reset()
        XCTAssertEqual(tracking, [true, false])
        XCTAssertEqual(secondTouches, 0)
        XCTAssertTrue(recognizer.observeTouchBegin(firstView: note, count: 1))
        XCTAssertTrue(recognizer.observeTouchBegin(firstView: UIView(), count: 1))
        XCTAssertEqual(secondTouches, 1)
        recognizer.reset()
        XCTAssertEqual(tracking, [true, false, true, false])
        XCTAssertNil(recognizer.note)
        XCTAssertTrue(recognizer.observeTouchBegin(firstView: note, count: 2))
        XCTAssertEqual(secondTouches, 2)
        recognizer.reset()
        XCTAssertEqual(tracking, [true, false, true, false, true, false])
    }

    func testDragKeepsDistanceBeforeRecognizerBegins() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let parent = UIView(frame: window.bounds); window.addSubview(parent)
        let note = PageElement(kind: .stickyNote, x: 40, y: 50, width: 100, height: 100)
        let control = StickyNoteControl(item: note)
        control.frame = CGRect(x: 40, y: 50, width: 100, height: 100)
        control.pageSize = CGSize(width: 400, height: 400); parent.addSubview(control)
        let pan = StickyTestPan(target: nil, action: nil); control.addGestureRecognizer(pan)
        let touch = StickyTestTouch(); touch.point = CGPoint(x: 100, y: 100)
        pan.recordInitialTouch(touch)
        var committed: PageElement?
        control.changed = { committed = $0 }
        pan.point = CGPoint(x: 120, y: 120); pan.simulatedState = .began
        control.perform(NSSelectorFromString("drag:"), with: pan)
        pan.point = CGPoint(x: 130, y: 130); pan.simulatedState = .changed
        control.perform(NSSelectorFromString("drag:"), with: pan)
        XCTAssertNil(committed)
        XCTAssertEqual(control.transform.tx, 30, accuracy: 0.001)
        pan.simulatedState = .ended
        control.perform(NSSelectorFromString("drag:"), with: pan)
        XCTAssertEqual(committed?.x, 70)
        XCTAssertEqual(committed?.y, 80)
    }

    func testCancelledDragAndResizeRestorePreviewWithoutCommit() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let parent = UIView(frame: window.bounds); window.addSubview(parent)
        var note = PageElement(kind: .stickyNote, x: 40, y: 50, width: 100, height: 100)
        note.rotation = .pi / 4
        let control = StickyNoteControl(item: note)
        control.frame = CGRect(x: 40, y: 50, width: 100, height: 100)
        control.transform = CGAffineTransform(rotationAngle: note.rotation ?? 0)
        control.pageSize = CGSize(width: 400, height: 400); parent.addSubview(control)
        let pan = StickyTestPan(target: nil, action: nil); control.addGestureRecognizer(pan)
        let touch = StickyTestTouch(); touch.point = CGPoint(x: 100, y: 100)
        pan.recordInitialTouch(touch)
        var commits = 0, cancelledMoves = 0, cancelledResizes = 0
        control.changed = { _ in commits += 1 }
        control.movePreviewCancelled = { cancelledMoves += 1 }
        control.resizePreviewCancelled = { cancelledResizes += 1 }
        pan.point = CGPoint(x: 120, y: 120); pan.simulatedState = .began
        control.perform(NSSelectorFromString("drag:"), with: pan)
        pan.point = CGPoint(x: 130, y: 130); pan.simulatedState = .changed
        control.perform(NSSelectorFromString("drag:"), with: pan)
        pan.simulatedState = .cancelled
        control.perform(NSSelectorFromString("drag:"), with: pan)
        XCTAssertEqual(control.item, note)
        XCTAssertEqual(control.transform, CGAffineTransform(rotationAngle: note.rotation ?? 0))
        XCTAssertEqual(cancelledMoves, 1)
        XCTAssertEqual(commits, 0)

        let originalBounds = control.bounds, originalCenter = control.center
        pan.point = CGPoint(x: 120, y: 120); pan.simulatedState = .began
        control.perform(NSSelectorFromString("resize:"), with: pan)
        pan.point = CGPoint(x: 130, y: 130); pan.simulatedState = .changed
        control.perform(NSSelectorFromString("resize:"), with: pan)
        XCTAssertNotEqual(control.bounds, originalBounds)
        pan.simulatedState = .cancelled
        control.perform(NSSelectorFromString("resize:"), with: pan)
        XCTAssertEqual(control.bounds, originalBounds)
        XCTAssertEqual(control.center, originalCenter)
        XCTAssertEqual(control.item, note)
        XCTAssertEqual(cancelledResizes, 1)
        XCTAssertEqual(commits, 0)
    }

    func testCompactNoteKeepsBodyAndResizeHandleHittable() {
        let control = StickyNoteControl(item: PageElement(kind: .stickyNote))
        control.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        control.setObjectSelected(true); control.layoutIfNeeded()
        XCTAssertTrue(control.hitTest(CGPoint(x: 22, y: 22), with: nil) === control)
        XCTAssertTrue(control.hitTest(CGPoint(x: 66, y: 22), with: nil) === control.resizeHandle)
    }

    func testMoveClampUsesZoomAndFullNoteBounds() {
        var note = PageElement(kind: .stickyNote, x: 30, y: 40, width: 100, height: 80)
        note.collapsed = true
        let control = StickyNoteControl(item: note)
        control.pageSize = CGSize(width: 200, height: 200); control.zoom = 2
        XCTAssertEqual(control.clampedTranslation(CGPoint(x: 500, y: -500)), CGPoint(x: 140, y: -80))
    }

    func testGroupMoveClampsChildrenAndLockedContentBlocksResize() {
        let note = PageElement(kind: .stickyNote, x: 30, y: 40, width: 100, height: 80)
        let control = StickyNoteControl(item: note)
        control.pageSize = CGSize(width: 200, height: 200); control.zoom = 2
        control.movementBounds = CGRect(x: 10, y: 10, width: 170, height: 150)
        XCTAssertEqual(control.clampedTranslation(CGPoint(x: 500, y: 500)), CGPoint(x: 40, y: 80))
        XCTAssertEqual(control.clampedTranslation(CGPoint(x: -500, y: -500)), CGPoint(x: -20, y: -20))
        control.setObjectSelected(true)
        var changes = 0
        control.changed = { _ in changes += 1 }
        control.canManipulate = false
        XCTAssertTrue(control.resizeHandle.isHidden)
        control.resizeNote(to: CGSize(width: 150, height: 150))
        XCTAssertEqual(control.item, note)
        XCTAssertEqual(changes, 0)
    }

    func testRotatedResizeKeepsOppositeCornerAndClampsToPage() {
        var note = PageElement(kind: .stickyNote, x: 150, y: 150, width: 100, height: 100)
        note.rotation = .pi / 2
        let control = StickyNoteControl(item: note)
        control.pageSize = CGSize(width: 400, height: 400)
        let resized = control.resizedItem(to: CGSize(width: 140, height: 120))
        func corner(_ note: PageElement) -> CGPoint {
            let center = CGPoint(x: note.x + note.width / 2, y: note.y + note.height / 2)
            let offset = CGPoint(x: -note.width / 2, y: -note.height / 2).applying(CGAffineTransform(rotationAngle: note.rotation ?? 0))
            return CGPoint(x: center.x + offset.x, y: center.y + offset.y)
        }
        XCTAssertEqual(corner(note).x, corner(resized).x, accuracy: 0.0001)
        XCTAssertEqual(corner(note).y, corner(resized).y, accuracy: 0.0001)
        let clamped = control.resizedItem(to: CGSize(width: 1000, height: 1000))
        XCTAssertGreaterThanOrEqual(clamped.x, 0)
        XCTAssertGreaterThanOrEqual(clamped.y, 0)
        XCTAssertLessThanOrEqual(clamped.x + clamped.width, 400)
        XCTAssertLessThanOrEqual(clamped.y + clamped.height, 400)
        XCTAssertEqual(corner(note).x, corner(clamped).x, accuracy: 0.0001)
        XCTAssertEqual(corner(note).y, corner(clamped).y, accuracy: 0.0001)
    }
}


@MainActor
final class StickyCornerResizeTests: XCTestCase {
    private func control(rotation: Double = 0) -> StickyNoteControl {
        var item = PageElement(kind: .stickyNote, x: 100, y: 100, width: 200, height: 160)
        item.rotation = rotation
        let control = StickyNoteControl(item: item)
        control.pageSize = CGSize(width: 800, height: 800); control.zoom = 1
        return control
    }

    func testEachCornerKeepsTheOppositeCornerFixed() {
        let c = control()
        let tl = c.resizedItem(to: CGSize(width: 250, height: 200), anchoredOpposite: 0)
        XCTAssertEqual(tl.x + tl.width, 300, accuracy: 0.001); XCTAssertEqual(tl.y + tl.height, 260, accuracy: 0.001)
        let tr = c.resizedItem(to: CGSize(width: 250, height: 200), anchoredOpposite: 1)
        XCTAssertEqual(tr.x, 100, accuracy: 0.001); XCTAssertEqual(tr.y + tr.height, 260, accuracy: 0.001)
        let bl = c.resizedItem(to: CGSize(width: 250, height: 200), anchoredOpposite: 2)
        XCTAssertEqual(bl.x + bl.width, 300, accuracy: 0.001); XCTAssertEqual(bl.y, 100, accuracy: 0.001)
        let br = c.resizedItem(to: CGSize(width: 250, height: 200))
        XCTAssertEqual(br.x, 100, accuracy: 0.001); XCTAssertEqual(br.y, 100, accuracy: 0.001)
    }

    func testCornerHandlesAreOnlyVisibleWhenSelected() {
        let c = control(); c.frame = CGRect(x: 0, y: 0, width: 200, height: 160); c.layoutIfNeeded()
        XCTAssertTrue(c.allResizeHandles.allSatisfy(\.isHidden))
        c.setObjectSelected(true)
        XCTAssertEqual(c.allResizeHandles.count, 4)
        XCTAssertTrue(c.allResizeHandles.allSatisfy { !$0.isHidden })
        XCTAssertEqual(c.allResizeHandles.map(\.tag).sorted(), [0, 1, 2, 3])
    }

    func testGripsSitOutsideCornersAndChevronAndCrossWork() {
        let control = StickyNoteControl(item: PageElement(kind: .stickyNote, x: 20, y: 20, width: 180, height: 160))
        control.frame = CGRect(x: 0, y: 0, width: 180, height: 160)
        control.setObjectSelected(true); control.layoutIfNeeded()
        // The bracket glyph is 9 pt into its 44 pt cell (mirrored per corner): every glyph corner is 5 pt outside the body.
        XCTAssertEqual(control.cornerHandles[0].frame.origin, CGPoint(x: -14, y: -14))
        XCTAssertEqual(control.cornerHandles[1].frame.minX + 35, 185)
        XCTAssertEqual(control.cornerHandles[2].frame.minY + 35, 165)
        XCTAssertEqual(CGPoint(x: control.resizeHandle.frame.minX + 35, y: control.resizeHandle.frame.minY + 35), CGPoint(x: 185, y: 165))
        XCTAssertTrue(control.point(inside: CGPoint(x: -10, y: -10), with: nil))
        XCTAssertTrue(control.hitTest(CGPoint(x: -8, y: -8), with: nil) === control.cornerHandles[0])
        XCTAssertFalse(control.point(inside: CGPoint(x: -20, y: -20), with: nil))
        var received: [PageElement?] = []
        control.changed = { received.append($0) }
        control.collapseButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(received.last??.collapsed, true)
        control.deleteButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(received.count, 2)
        XCTAssertNil(received[1])
    }
    func testChevronAndCrossStayOutOfTheWayOfWriting() {
        let control = StickyNoteControl(item: PageElement(kind: .stickyNote, x: 20, y: 20, width: 180, height: 160))
        control.frame = CGRect(x: 0, y: 0, width: 180, height: 160); control.layoutIfNeeded()
        XCTAssertFalse(control.collapseButton.isHidden)
        XCTAssertTrue(control.deleteButton.isHidden, "The cross appears only for the selected note")
        control.allowsBodySelection = false          // finger drawing owns the page
        XCTAssertTrue(control.collapseButton.isHidden)
        control.allowsBodySelection = true; control.canManipulate = false   // read-only
        XCTAssertTrue(control.collapseButton.isHidden && control.deleteButton.isHidden)
        var locked = PageElement(kind: .stickyNote, x: 20, y: 20, width: 180, height: 160); locked.isLocked = true
        let lockedControl = StickyNoteControl(item: locked)
        XCTAssertTrue(lockedControl.collapseButton.isHidden && lockedControl.deleteButton.isHidden)
    }
}
