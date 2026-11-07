import SwiftUI
import XCTest
import UIKit
@testable import OpenNotes

final class NativeInkGestureTests: XCTestCase {
    private func stroke(_ points: [CGPoint], pressure: [CGFloat] = [], width: CGFloat = 4) -> InkStroke {
        let samples = points.enumerated().map { index, point in
            InkStrokePoint(location: point, timeOffset: Double(index) / 120,
                           size: CGSize(width: width, height: width), opacity: 1,
                           force: pressure.isEmpty ? 0.5 : pressure[index], azimuth: 0, altitude: .pi / 2)
        }
        return InkStroke(ink: InkInk(.pen, color: .blue), path: InkStrokePath(controlPoints: samples, creationDate: Date(timeIntervalSince1970: 0)))
    }

    func testBallIgnoresPressureAndOtherProfilesVaryWhileRawSamplesStayExact() throws {
        let source = stroke((0...20).map { CGPoint(x: $0 * 4, y: 20) }, pressure: (0...20).map { CGFloat($0) / 20 })
        var settings = EditorToolSettings()
        settings.pressureEnabled = true
        settings.tipSharpness = 1
        let ball = try XCTUnwrap(StrokeProcessing.process(source, tool: .pen, width: 8, settings: settings, shapeHeld: false))
        XCTAssertEqual(ball.style?.sharpness, 0)
        XCTAssertTrue(ball.path.allSatisfy { $0.size == CGSize(width: 8, height: 8) })
        var profiles: [CGFloat] = []
        for kind in [EditorToolSettings.PenStyle.fountain, .brush] {
            settings.penStyle = kind
            let result = try XCTUnwrap(StrokeProcessing.process(source, tool: .pen, width: 8, settings: settings, shapeHeld: false))
            XCTAssertLessThan(result.path.first!.size.width, result.path.last!.size.width)
            XCTAssertEqual(result.rawSamples.map(\.location), source.path.map(\.location))
            XCTAssertEqual(result.rawSamples.map(\.force), source.path.map(\.force))
            profiles.append(result.path.last!.size.width - result.path.first!.size.width)
        }
        XCTAssertGreaterThan(profiles[1], profiles[0])
    }

    func testPartialEraseCreatesIndependentFragmentsAndKeepsSeparateDot() throws {
        let line = stroke([CGPoint(x: 10, y: 50), CGPoint(x: 150, y: 50)])
        let dot = stroke([CGPoint(x: 80, y: 25)])
        let original = InkDrawing(strokes: [line, dot])
        let erased = EraserEditing.erase(original, along: [CGPoint(x: 80, y: 40), CGPoint(x: 80, y: 60)], width: 10, mode: .pixel)
        XCTAssertEqual(erased.strokes.count, 3)
        XCTAssertEqual(erased.strokes.last?.id, dot.id)
        let pieces = Array(erased.strokes.dropLast())
        XCTAssertTrue(pieces.allSatisfy { $0.id != line.id })
        XCTAssertNotEqual(pieces[0].id, pieces[1].id)
        XCTAssertLessThan(pieces[0].path.last!.location.x, 80)
        XCTAssertGreaterThan(pieces[1].path.first!.location.x, 80)
        let reopened = try InkDrawing(data: erased.dataRepresentation())
        XCTAssertEqual(reopened.dataRepresentation(), erased.dataRepresentation())
        XCTAssertEqual(original.strokes[0].id, line.id)
        XCTAssertEqual(original.strokes[0].path.count, 2)
    }

    func testEraserDoesNotHitPatternGapsOrBoundingBoxOnly() throws {
        var dashed = stroke([CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)])
        dashed.style = InkStyle(kind: .ballpoint, width: 4, pattern: .dashed)
        let drawing = InkDrawing(strokes: [dashed])
        let gap = EraserEditing.erase(drawing, along: [CGPoint(x: 16, y: 50)], width: 1, mode: .stroke)
        XCTAssertEqual(gap.dataRepresentation(), drawing.dataRepresentation())
        XCTAssertTrue(EraserEditing.erase(drawing, along: [CGPoint(x: 6, y: 50)], width: 1, mode: .stroke).strokes.isEmpty)
        let diagonal = stroke([.zero, CGPoint(x: 100, y: 100)])
        let remote = InkDrawing(strokes: [diagonal])
        XCTAssertEqual(EraserEditing.erase(remote, along: [CGPoint(x: 10, y: 90)], width: 5, mode: .pixel).dataRepresentation(), remote.dataRepresentation())
    }

    func testScribbleNeedsRepetitionCrossingsAndActualInkOverlap() {
        let points = [CGPoint(x: 20, y: 30), CGPoint(x: 140, y: 80), CGPoint(x: 25, y: 75), CGPoint(x: 135, y: 25),
                      CGPoint(x: 30, y: 30), CGPoint(x: 130, y: 80), CGPoint(x: 35, y: 75), CGPoint(x: 125, y: 25),
                      CGPoint(x: 40, y: 30), CGPoint(x: 120, y: 80), CGPoint(x: 45, y: 75), CGPoint(x: 115, y: 25), CGPoint(x: 50, y: 30)]
        let ink = InkDrawing(strokes: [stroke([CGPoint(x: 10, y: 50), CGPoint(x: 150, y: 50)])])
        XCTAssertTrue(InkGestureRecognition.isScribble(points, over: ink))
        XCTAssertFalse(InkGestureRecognition.isScribble(points, over: InkDrawing()))
        let handwriting = (0...30).map { CGPoint(x: $0 * 4, y: $0.isMultiple(of: 2) ? 30 : 70) }
        XCTAssertFalse(InkGestureRecognition.isScribble(handwriting, over: ink))
        XCTAssertFalse(InkGestureRecognition.isScribble(points.map { CGPoint(x: $0.x + 300, y: $0.y) }, over: ink))
    }

    func testCircleCandidateRequiresClosedRoundContourAndContourHit() throws {
        let circle = (0...64).map { index in
            let angle = CGFloat(index) * 2 * .pi / 64
            return CGPoint(x: 100 + 50 * cos(angle), y: 100 + 50 * sin(angle))
        }
        XCTAssertNotNil(InkGestureRecognition.circle(circle))
        XCTAssertNil(InkGestureRecognition.circle(Array(circle.prefix(40))))
        XCTAssertNil(InkGestureRecognition.circle([.zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100), .zero]))
        XCTAssertTrue(InkGestureRecognition.isOnContour(CGPoint(x: 150, y: 100), contour: circle, tolerance: 4))
        XCTAssertFalse(InkGestureRecognition.isOnContour(CGPoint(x: 100, y: 100), contour: circle, tolerance: 4))
    }

    func testPolygonAndSmoothCurveRecognitionRemainConservative() throws {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 50, y: 90), .zero]
        var triangle: [CGPoint] = []
        for edge in 0..<3 {
            let a = corners[edge], b = corners[edge + 1]
            for index in 0..<16 {
                let t = CGFloat(index) / 16
                let x = a.x + (b.x - a.x) * t
                let y = a.y + (b.y - a.y) * t
                triangle.append(CGPoint(x: x, y: y))
            }
        }
        triangle.append(.zero)
        XCTAssertEqual(ShapeRecognition.recognize(triangle)?.count, 4)
        let curve = (0...48).map { index in
            let t = CGFloat(index) / 48
            return CGPoint(x: 200 * t, y: 160 * t * (1 - t))
        }
        XCTAssertNotNil(ShapeRecognition.recognize(curve))
        XCTAssertNil(ShapeRecognition.recognize([.zero, CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 0)]))
    }
}

private final class InputTouch: UITouch {
    let kind: UITouch.TouchType
    init(_ kind: UITouch.TouchType) { self.kind = kind; super.init() }
    override var type: UITouch.TouchType { kind }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 100, y: 100) }
    override var timestamp: TimeInterval { 1 }
    override var altitudeAngle: CGFloat { .pi / 2 }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

// Finger navigates, Pencil acts: the interaction rules of the editor, driven through the real views.
@MainActor
final class EditorInputRulesTests: XCTestCase {
    private func stroke(_ a: CGPoint, _ b: CGPoint, parent: UUID? = nil) -> InkStroke {
        let points = (0...8).map { index -> InkStrokePoint in
            let t = CGFloat(index) / 8
            return InkStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(index), size: CGSize(width: 3, height: 3), opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
        }
        var result = InkStroke(ink: InkInk(.pen, color: .black), path: InkStrokePath(controlPoints: points, creationDate: Date()))
        result.parentID = parent
        return result
    }
    private func session(elements: [PageElement] = [], drawing: InkDrawing = InkDrawing()) -> EditorSession {
        let suite = "input-rules-\(UUID())"
        let noteID = UUID()
        var page = NotePage(noteID: noteID, index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "d")
        page.width = 794; page.height = 1123; page.elements = elements
        var document = NoteDocument(id: noteID, folderID: NotebookFolder.homeID, title: "t"); document.pageIDs = [page.id]
        var home = NotebookFolder(id: NotebookFolder.homeID, name: "Home"); home.noteIDs = [noteID]
        let store = LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        var library = NoteLibrarySnapshot(); library.folders = [home]; library.notes = [document]; library.pages = [page]
        store.library = library
        let result = EditorSession(store: store, noteID: noteID, preferences: UserDefaults(suiteName: suite)!)
        result.selectedTool = .pen
        result.page = page; result.drawing = drawing; result.canvas.drawing = drawing
        return result
    }
    private func hosted(_ canvas: WritingCanvas) throws -> (PageScrollView, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 1100)
        window.rootViewController = UIHostingController(rootView: canvas)
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        func find(_ view: UIView) -> PageScrollView? { (view as? PageScrollView) ?? view.subviews.lazy.compactMap(find).first }
        return (try XCTUnwrap(find(window)), window)
    }

    func testFingerModeLassoAcceptsTheFinger() throws {
        let view = PageScrollView(canvas: InkCanvasView())
        view.configureSelection(true, immediate: false, selected: nil)
        view.fingerScrollsSelection = false
        let selection = try XCTUnwrap(view.selectionView)
        for gesture in selection.activeGestures where !(gesture is UILongPressGestureRecognizer) {
            XCTAssertTrue(gesture.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)))
        }
    }
    func testFingerModeKeepsTwoFingerPageTurnAndHoldDoesNotCancelStrokes() throws {
        let (view, window) = try hosted(WritingCanvas(session: session(), finger: true, reading: false))
        defer { window.isHidden = true }
        XCTAssertFalse(view.pageTurn.disabled)
        XCTAssertEqual(view.pageTurn.gesture.minimumNumberOfTouches, 2)
        XCTAssertFalse(view.pasteHold.isEnabled)
    }
    func testPencilModeLongPressStaysAvailable() throws {
        let (view, window) = try hosted(WritingCanvas(session: session(), finger: false, reading: false))
        defer { window.isHidden = true }
        XCTAssertTrue(view.pasteHold.isEnabled)
    }
    func testFingerTapOnInkKeepsTheToolButStillOpensImages() throws {
        var image = PageElement(kind: .image, x: 400, y: 400, width: 100, height: 100)
        image.resource = "image.png"
        let editor = session(elements: [image], drawing: InkDrawing(strokes: [stroke(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100))]))
        var opened: UUID?
        let (view, window) = try hosted(WritingCanvas(session: editor, finger: false, reading: false, editImage: { opened = $0 }))
        defer { window.isHidden = true }
        let canvas = view.canvas
        func screen(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * canvas.zoomScale - canvas.contentOffset.x, y: y * canvas.zoomScale - canvas.contentOffset.y) }
        XCTAssertEqual(view.onImageTap?(screen(200, 100)), false)
        XCTAssertEqual(editor.selectedTool, .pen)
        XCTAssertEqual(view.onImageTap?(screen(450, 450)), true)
        XCTAssertEqual(opened, image.id)
    }
    func testPencilStrokeLocksFingerNavigationButFingerStrokeDoesNot() {
        let canvas = InkCanvasView()
        canvas.setPageSize(CGSize(width: 300, height: 300))
        canvas.drawingPolicy = .anyInput
        let view = PageScrollView(canvas: canvas)
        let pencil = InputTouch(.pencil)
        canvas.inkContentView.touchesBegan([pencil], with: nil)
        XCTAssertTrue(canvas.hasActivePencilStroke)
        XCTAssertFalse(view.gestureRecognizerShouldBegin(view.zoomGesture))
        XCTAssertFalse(view.gestureRecognizerShouldBegin(view.pasteHold))
        XCTAssertFalse(canvas.gestureRecognizerShouldBegin(canvas.panGestureRecognizer))
        XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: 500, y: 0)))
        canvas.inkContentView.touchesCancelled([pencil], with: nil)
        XCTAssertTrue(view.gestureRecognizerShouldBegin(view.zoomGesture))
        let finger = InputTouch(.direct)
        canvas.inkContentView.touchesBegan([finger], with: nil)
        XCTAssertTrue(canvas.hasActiveStroke)
        XCTAssertFalse(canvas.hasActivePencilStroke)
        XCTAssertTrue(view.gestureRecognizerShouldBegin(view.zoomGesture), "A second finger must still start navigation")
        canvas.inkContentView.touchesCancelled([finger], with: nil)
    }
    func testUndoDropsTheSelectionAndAnyDragInProgress() throws {
        let editor = session()
        let view = PageScrollView(canvas: editor.canvas)
        let coordinator = WritingCanvas.Coordinator(session: editor, zoomWindow: false)
        coordinator.container = view
        view.configureSelection(true, session: editor, immediate: false, selected: nil)
        let selection = try XCTUnwrap(view.selectionView)
        var committed = 0
        selection.moved = { _, _ in committed += 1 }
        selection.installSelection(UIBezierPath(rect: CGRect(x: 50, y: 50, width: 100, height: 100)))
        selection.updateDrag(state: .began, point: CGPoint(x: 80, y: 80), translation: .zero)
        NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: editor.canvas.undoManager)
        XCTAssertNil(selection.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first?.path)
        XCTAssertTrue(selection.selectionBounds.isEmpty)
        selection.updateDrag(state: .changed, point: CGPoint(x: 90, y: 90), translation: CGPoint(x: 10, y: 10))
        selection.updateDrag(state: .ended, point: CGPoint(x: 90, y: 90), translation: CGPoint(x: 10, y: 10))
        XCTAssertEqual(committed, 0, "A drag that outlived an undo must not commit")
    }
    func testContentHiddenByACollapsedNoteCannotBeSelected() {
        var note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 300, height: 300); note.collapsed = true
        var child = PageElement(kind: .rectangle, x: 250, y: 250, width: 60, height: 60); child.parentID = note.id
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "d")
        page.width = 794; page.height = 1123; page.elements = [note, child]
        let hiddenInk = stroke(CGPoint(x: 110, y: 110), CGPoint(x: 130, y: 120), parent: note.id)
        var filtered = EditorToolSettings(); filtered.includeStickyNotes = false
        XCTAssertTrue(SelectionMoveSnapshot(page: page, drawing: InkDrawing(), path: UIBezierPath(rect: CGRect(x: 230, y: 230, width: 100, height: 100)), settings: filtered).isEmpty)
        XCTAssertTrue(SelectionMoveSnapshot(page: page, drawing: InkDrawing(strokes: [hiddenInk]), path: UIBezierPath(rect: CGRect(x: 100, y: 100, width: 44, height: 44)), settings: filtered).isEmpty)
        // Selecting the note itself still carries what it owns.
        let owned = SelectionMoveSnapshot(page: page, drawing: InkDrawing(strokes: [hiddenInk]), path: UIBezierPath(rect: CGRect(x: 100, y: 100, width: 44, height: 44)), settings: EditorToolSettings())
        XCTAssertTrue(owned.elementIDs.contains(child.id)); XCTAssertEqual(owned.strokeIndices.count, 1)
    }
    func testSelectionStillRespectsOcclusionAfterTheCheapTestRunsFirst() {
        let note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 200, height: 200)
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "d")
        page.width = 794; page.height = 1123; page.elements = [note]
        let covered = stroke(CGPoint(x: 150, y: 150), CGPoint(x: 200, y: 150))
        let crossing = stroke(CGPoint(x: 50, y: 250), CGPoint(x: 150, y: 250))
        let drawing = InkDrawing(strokes: [covered, crossing])
        var settings = EditorToolSettings(); settings.includeStickyNotes = false
        XCTAssertTrue(SelectionMoveSnapshot(page: page, drawing: drawing, path: UIBezierPath(rect: CGRect(x: 140, y: 140, width: 70, height: 20)), settings: settings).isEmpty, "Ink under a note is not selectable")
        XCTAssertTrue(SelectionMoveSnapshot(page: page, drawing: drawing, path: UIBezierPath(rect: CGRect(x: 120, y: 240, width: 30, height: 20)), settings: settings).isEmpty, "Only the covered part of the stroke is inside")
        XCTAssertEqual(SelectionMoveSnapshot(page: page, drawing: drawing, path: UIBezierPath(rect: CGRect(x: 40, y: 240, width: 30, height: 20)), settings: settings).strokeIndices, [1])
    }
    func testLivePreviewClipsLikeTheCommit() throws {
        let back = PageElement(kind: .stickyNote, x: 100, y: 100, width: 200, height: 200)
        let front = PageElement(kind: .stickyNote, x: 250, y: 150, width: 100, height: 100)
        var locked = PageElement(kind: .stickyNote, x: 500, y: 100, width: 100, height: 100); locked.isLocked = true
        let occlusion = StickyInkOcclusion([back, front, locked])
        let page = CGRect(x: 0, y: 0, width: 794, height: 1123)
        let inside = try XCTUnwrap(occlusion.previewMask(startingAt: CGPoint(x: 150, y: 150), in: page)?.path)
        XCTAssertTrue(inside.contains(CGPoint(x: 200, y: 200)))
        XCTAssertFalse(inside.contains(CGPoint(x: 50, y: 50)), "Ink started in a note stays in it")
        XCTAssertFalse(inside.contains(CGPoint(x: 270, y: 200)), "A note above the parent covers its ink")
        let outside = try XCTUnwrap(occlusion.previewMask(startingAt: CGPoint(x: 50, y: 50), in: page)?.path)
        XCTAssertTrue(outside.contains(CGPoint(x: 700, y: 700)))
        XCTAssertFalse(outside.contains(CGPoint(x: 150, y: 150)), "Page ink passes under notes")
        let onLocked = try XCTUnwrap(occlusion.previewMask(startingAt: CGPoint(x: 550, y: 150), in: page)?.path)
        XCTAssertFalse(onLocked.contains(CGPoint(x: 550, y: 150)), "A locked note does not take ink")
        XCTAssertNil(StickyInkOcclusion([]).previewMask(startingAt: .zero, in: page))
    }
    func testDeleteCrossNeverOverlapsAGripAndIsReachable() {
        let control = StickyNoteControl(item: PageElement(kind: .stickyNote, x: 0, y: 0, width: 220, height: 180))
        control.bounds = CGRect(x: 0, y: 0, width: 220, height: 180)
        control.setObjectSelected(true); control.layoutIfNeeded()
        for handle in control.allResizeHandles {
            XCTAssertFalse(handle.frame.intersects(control.deleteButton.frame))
            XCTAssertTrue(control.hitTest(CGPoint(x: handle.frame.midX, y: handle.frame.midY), with: nil) === handle)
        }
        let cross = CGPoint(x: control.deleteButton.frame.midX, y: control.deleteButton.frame.midY)
        XCTAssertTrue(control.hitTest(cross, with: nil)?.isDescendant(of: control.deleteButton) == true)
        XCTAssertGreaterThanOrEqual(control.deleteButton.bounds.width, 44)
        XCTAssertFalse(control.deleteButton.frame.intersects(CGRect(x: control.collapseButton.frame.minX, y: control.collapseButton.frame.minY + 1, width: 44, height: 20)))
    }
    func testLongPressMenusAreNotVetoedByTheInkView() {
        let view = PageScrollView(canvas: InkCanvasView())
        XCTAssertTrue(view.canvas.inkContentView.gestureRecognizerShouldBegin(view.pasteHold), "The paste hold is attached above the ink view")
        let own = view.canvas.inkContentView.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer }
        XCTAssertEqual(own.map { view.canvas.inkContentView.gestureRecognizerShouldBegin($0) }, false, "The circle hold stays off without a circle")
    }
    func testSelectionKeepsItsStrokesAfterMovingOverOthers() async throws {
        let a = stroke(CGPoint(x: 100, y: 100), CGPoint(x: 160, y: 100)), b = stroke(CGPoint(x: 400, y: 100), CGPoint(x: 460, y: 100))
        let editor = session(drawing: InkDrawing(strokes: [a, b]))
        let page = try XCTUnwrap(editor.page)
        let lasso = UIBezierPath(rect: CGRect(x: 80, y: 80, width: 100, height: 40))
        editor.selectionIDs = editor.selectionSnapshot(page, path: lasso).identity
        XCTAssertEqual(editor.selectionIDs?.strokeIDs, [a.id])
        let moved = await editor.moveSelection(inside: lasso, by: CGPoint(x: 300, y: 0), durable: false)
        XCTAssertTrue(moved)
        let over = UIBezierPath(cgPath: lasso.cgPath); over.apply(CGAffineTransform(translationX: 300, y: 0))
        XCTAssertEqual(editor.selectionSnapshot(try XCTUnwrap(editor.page), path: over).strokeIDs, [a.id], "Moving over B must not pick B up")
        editor.selectionIDs = nil
        XCTAssertEqual(editor.selectionSnapshot(try XCTUnwrap(editor.page), path: over).strokeIDs.count, 2, "Without an identity the outline decides")
    }
    func testTapSelectsOnlyTheTappedStroke() throws {
        let diagonal = stroke(CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 500)), neighbour = stroke(CGPoint(x: 280, y: 320), CGPoint(x: 290, y: 330))
        let editor = session(drawing: InkDrawing(strokes: [diagonal, neighbour]))
        let view = PageScrollView(canvas: editor.canvas)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 1100); view.pageSize = CGSize(width: 794, height: 1123); view.layoutIfNeeded()
        view.configureSelection(true, session: editor, immediate: false, selected: nil)
        let canvas = view.canvas
        let tap = CGPoint(x: 200 * canvas.zoomScale - canvas.contentOffset.x, y: 400 * canvas.zoomScale - canvas.contentOffset.y)
        XCTAssertNotNil(view.selectionView?.directSelection?(tap))
        XCTAssertEqual(editor.selectionIDs?.strokeIDs, [diagonal.id])
        XCTAssertEqual(editor.selectionSnapshot(try XCTUnwrap(editor.page), path: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 794, height: 1123))).strokeIDs, [diagonal.id])
        view.selectionView?.selectionDiscarded?()
        XCTAssertNil(editor.selectionIDs)
    }
    func testOpenNoteBodyBelongsToThePage() {
        let note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 200, height: 200)
        var collapsed = PageElement(kind: .stickyNote, x: 500, y: 100, width: 200, height: 200); collapsed.collapsed = true
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "d")
        page.width = 794; page.height = 1123; page.elements = [note, collapsed]
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 1100); view.pageSize = CGSize(width: 794, height: 1123)
        view.configureNotes(page, edit: nil) { _, _ in }
        view.layoutIfNeeded()
        let canvas = view.canvas
        func screen(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * canvas.zoomScale - canvas.contentOffset.x, y: y * canvas.zoomScale - canvas.contentOffset.y) }
        let open = view.noteViews.first { $0.item.id == note.id }!
        XCTAssertTrue(view.note(at: screen(200, 200)) === open)
        XCTAssertTrue(view.hitTest(screen(200, 200), with: nil).map { $0 === canvas || $0.isDescendant(of: canvas) } == true, "Pencil and scroll reach the canvas")
        XCTAssertNil(view.note(at: screen(50, 50)))
        XCTAssertNil(view.note(at: screen(520, 120)), "A collapsed note keeps its own tap and hold")
        open.setObjectSelected(true)
        XCTAssertTrue(open.canDragBody)
    }
    func testZoomingWhileEditingKeepsTheFontSize() throws {
        var note = PageElement(kind: .stickyNote, x: 0, y: 0, width: 220, height: 180); note.text = "abc"
        note.richTextRTF = try RichTextDocument.encode(NSAttributedString(string: "abc", attributes: [.font: UIFont.systemFont(ofSize: 16)]))
        let control = StickyNoteControl(item: note)
        control.bounds = CGRect(x: 0, y: 0, width: 220, height: 180)
        var saved: PageElement?
        control.changed = { saved = $0 }
        control.zoom = 1
        control.beginInlineEditing()
        control.zoom = 2
        try XCTUnwrap(control.subviews.compactMap { $0 as? UITextView }.first).insertText("d")
        control.endInlineEditing()
        let font = RichTextDocument.attributed(try XCTUnwrap(saved)).attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertEqual(font?.pointSize, 16)
    }
}
