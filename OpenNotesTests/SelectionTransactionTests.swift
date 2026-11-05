import XCTest
import UIKit
@testable import OpenNotes

@MainActor
final class SelectionTransactionTests: XCTestCase {
    private func stroke(_ a: CGPoint, _ b: CGPoint) -> InkStroke {
        let points = [a, b].enumerated().map { index, point in
            InkStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 10, height: 10), opacity: 1, force: 1, azimuth: 0, altitude: 1)
        }
        return InkStroke(ink: InkInk(.pen, color: .blue), path: InkStrokePath(controlPoints: points, creationDate: Date()))
    }
    func testVisibleStrokeSelectionIncludesCrossingAndWidth() {
        let line = stroke(CGPoint(x: 10, y: 50), CGPoint(x: 150, y: 50))
        XCTAssertTrue(DocumentClipboard.contains(line, inside: UIBezierPath(rect: CGRect(x: 49, y: 45, width: 2, height: 2))))
        XCTAssertFalse(DocumentClipboard.contains(line, inside: UIBezierPath(rect: CGRect(x: 40, y: 70, width: 5, height: 5))))
    }
    func testRotatedObjectHitTestingUsesVisibleGeometry() {
        var item = PageElement(kind: .text, x: 100, y: 100, width: 100, height: 20)
        item.rotation = .pi / 2
        XCTAssertEqual(item.visibleBounds.midX, 150, accuracy: 0.001)
        XCTAssertEqual(item.visibleBounds.midY, 110, accuracy: 0.001)
        XCTAssertEqual(item.visibleBounds.width, 20, accuracy: 0.001)
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.elements = [item]
        XCTAssertEqual(DocumentClipboard.selectedElements(page, inside: UIBezierPath(rect: CGRect(x: 145, y: 65, width: 5, height: 5)), settings: EditorToolSettings()).count, 1)
        XCTAssertTrue(DocumentClipboard.selectedElements(page, inside: UIBezierPath(rect: CGRect(x: 105, y: 105, width: 5, height: 5)), settings: EditorToolSettings()).isEmpty)
    }
    func testMixedClipboardRemapsIDsAndParentLinks() throws {
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        let parent = PageElement(kind: .stickyNote, x: 100, y: 100, width: 160, height: 160)
        var child = PageElement(kind: .text, x: 120, y: 120, width: 60, height: 30)
        child.parentID = parent.id
        var ink = stroke(CGPoint(x: 130, y: 140), CGPoint(x: 160, y: 160)); ink.parentID = parent.id
        page.elements = [parent, child]
        let drawing = InkDrawing(strokes: [ink])
        let payload = try DocumentClipboard.payload(page: page, drawing: drawing, path: UIBezierPath(rect: CGRect(x: 90, y: 90, width: 200, height: 200)), settings: EditorToolSettings(), resources: [:])
        let (pasted, elements, _) = try DocumentClipboard.decode(DocumentClipboard.encode(payload), on: page, at: CGPoint(x: 350, y: 350))
        let newParent = try XCTUnwrap(elements.first(where: { $0.kind == .stickyNote }))
        XCTAssertNotEqual(newParent.id, parent.id)
        XCTAssertNotEqual(pasted.strokes.first?.id, ink.id)
        XCTAssertEqual(pasted.strokes.first?.parentID, newParent.id)
        XCTAssertEqual(elements.first(where: { $0.kind == .text })?.parentID, newParent.id)
        XCTAssertEqual(newParent.x, 350, accuracy: 0.001)
        XCTAssertThrowsError(try DocumentClipboard.decode(Data("bad".utf8), on: page, at: .zero))
    }
    func testParentSelectionIncludesChildOutsideLassoAndDisabledInkFilter() {
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        let parent = PageElement(kind: .stickyNote, x: 100, y: 100, width: 160, height: 160)
        var ink = stroke(CGPoint(x: 200, y: 200), CGPoint(x: 230, y: 230)); ink.parentID = parent.id
        page.elements = [parent]
        var settings = EditorToolSettings(); settings.includeHandwriting = false
        let snapshot = SelectionMoveSnapshot(page: page, drawing: InkDrawing(strokes: [ink]), path: UIBezierPath(rect: CGRect(x: 100, y: 100, width: 10, height: 10)), settings: settings)
        XCTAssertEqual(snapshot.strokeIndices, [0])
        XCTAssertEqual(snapshot.elementIDs, [parent.id])
    }
    func testStickySelectionDoesNotPickUpCoveredPageInk() {
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        let note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 160, height: 160)
        page.elements = [note]
        let background = stroke(CGPoint(x: 120, y: 150), CGPoint(x: 240, y: 150))
        var owned = background; owned.id = UUID(); owned.parentID = note.id
        let exposed = stroke(CGPoint(x: 80, y: 90), CGPoint(x: 280, y: 90))
        let snapshot = SelectionMoveSnapshot(page: page, drawing: InkDrawing(strokes: [background, owned, exposed]),
            path: UIBezierPath(rect: CGRect(x: 90, y: 90, width: 180, height: 180)), settings: EditorToolSettings())
        XCTAssertEqual(snapshot.elementIDs, [note.id])
        XCTAssertEqual(snapshot.strokeIndices, [1, 2])
    }
    func testOverlappingStickyTapSelectsOnlyTheVisibleNote() {
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        let back = PageElement(kind: .stickyNote, x: 100, y: 100, width: 160, height: 160)
        let front = PageElement(kind: .stickyNote, x: 120, y: 120, width: 160, height: 160)
        page.elements = [back, front]
        let hit = UIBezierPath(ovalIn: CGRect(x: 140, y: 140, width: 8, height: 8))
        XCTAssertEqual(DocumentClipboard.selectedElements(page, inside: hit, settings: EditorToolSettings()).map(\.id), [front.id])
        let exact = UIBezierPath(rect: front.visibleBounds)
        XCTAssertEqual(SelectionMoveSnapshot(page: page, drawing: InkDrawing(), path: exact, settings: EditorToolSettings()).elementIDs, [front.id])
    }
    func testHiddenResizeHandlesKeepSelectionMovable() {
        let view = PageSelectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.installSelection(UIBezierPath(rect: CGRect(x: 50, y: 50, width: 100, height: 100)))
        XCTAssertFalse(view.showsResizeHandles)
        XCTAssertTrue(view.subviews.allSatisfy(\.isHidden))
        XCTAssertTrue(view.hitTest(CGPoint(x: 50, y: 50), with: nil) === view)
        view.showsResizeHandles = true
        XCTAssertTrue(view.subviews.contains { !$0.isHidden && $0.isUserInteractionEnabled })
        XCTAssertTrue(view.subviews.filter { !$0.isHidden }.allSatisfy { $0.bounds.size == CGSize(width: 44, height: 44) })
        view.showsResizeHandles = false
        XCTAssertTrue(view.subviews.allSatisfy(\.isHidden))
        XCTAssertTrue(view.subviews.allSatisfy { !$0.isUserInteractionEnabled })
        XCTAssertTrue(view.hitTest(CGPoint(x: 50, y: 50), with: nil) === view)
        var moved = false
        view.moved = { _, _ in moved = true }
        view.updateDrag(state: .began, point: CGPoint(x: 80, y: 80), translation: .zero)
        view.updateDrag(state: .ended, point: CGPoint(x: 90, y: 90), translation: CGPoint(x: 10, y: 10))
        XCTAssertTrue(moved)
        view.installSelection(UIBezierPath(rect: CGRect(x: 50, y: 50, width: 100, height: 100)))
        view.showsResizeHandles = true
        XCTAssertTrue(view.subviews.contains { !$0.isHidden })
    }
    func testFinishedMoveDoesNotRestoreSelectionAfterLeavingAndReturningToLasso() async throws {
        let suite = "lasso-lifecycle-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let session = EditorSession(store: LibraryStore(root: root), noteID: UUID(), preferences: preferences)
        session.selectedTool = .lasso
        let view = PageScrollView(canvas: session.canvas)
        var completion: CheckedContinuation<Bool, Never>?
        view.configureSelection(true, session: session, immediate: false, moved: { _, _ in
            await withCheckedContinuation { completion = $0 }
        }, selected: nil)
        let original = try XCTUnwrap(view.subviews.compactMap { $0 as? PageSelectionView }.first)
        let path = UIBezierPath(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        original.installSelection(path)
        original.moved?(path, CGPoint(x: 10, y: 10))
        await Task.yield()
        let pending = try XCTUnwrap(completion)
        session.selectedTool = .pen
        view.configureSelection(false, session: session, immediate: false, selected: nil)
        session.selectedTool = .lasso
        view.configureSelection(true, session: session, immediate: false, selected: nil)
        let fresh = try XCTUnwrap(view.subviews.compactMap { $0 as? PageSelectionView }.first)
        XCTAssertFalse(original === fresh)
        pending.resume(returning: true)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertTrue(fresh.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.allSatisfy { $0.path == nil } == true)
    }
    func testSnapUsesPageAxesAndCanBeDisabled() {
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.width = 400; page.height = 500
        page.elements = [PageElement(kind: .stickyNote, x: 50, y: 50, width: 100, height: 100)]
        let region = UIBezierPath(rect: CGRect(x: 40, y: 40, width: 120, height: 120))
        var settings = EditorToolSettings(); settings.alignObjects = true
        var snapshot = SelectionMoveSnapshot(page: page, drawing: InkDrawing(), path: region, settings: settings)
        XCTAssertEqual(snapshot.snap(CGPoint(x: 97, y: 0), tolerance: 5).0.x, 100)
        settings.alignObjects = false
        snapshot = SelectionMoveSnapshot(page: page, drawing: InkDrawing(), path: region, settings: settings)
        XCTAssertEqual(snapshot.snap(CGPoint(x: 97, y: 0), tolerance: 5).0.x, 97)
    }
    func testLockedInkIsSelectableButProtected() {
        let page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        var ink = stroke(CGPoint(x: 30, y: 30), CGPoint(x: 100, y: 50)); ink.isLocked = true
        let snapshot = SelectionMoveSnapshot(page: page, drawing: InkDrawing(strokes: [ink]), path: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 200, height: 200)), settings: EditorToolSettings())
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertTrue(snapshot.containsLockedObjects)
    }
    func testAffineResizeAndRotationPersistAndReadOnlyRejectsChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(root: directory); await store.load()
        let created = await store.create(); let id = try XCTUnwrap(created)
        let suite = "selection-transform-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = EditorSession(store: store, noteID: id, preferences: preferences); await session.open()
        let pageID = try XCTUnwrap(session.page?.id)
        let note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 100, height: 100)
        let applied = await session.apply(.init(pageID: pageID, kind: .upsertElement, element: note)); XCTAssertTrue(applied)
        let path = UIBezierPath(rect: CGRect(x: 90, y: 90, width: 120, height: 120))
        let resized = await session.affineSelection(inside: path, scale: 2, rotation: 0, scaleY: 1, anchor: CGPoint(x: 100, y: 150)); XCTAssertTrue(resized)
        XCTAssertEqual(session.page?.elements?.first?.width, 200)
        XCTAssertEqual(session.page?.elements?.first?.height, 100)
        XCTAssertEqual(session.page?.elements?.first?.x, 100)
        let rotationRegion = UIBezierPath(rect: CGRect(x: 90, y: 90, width: 220, height: 120))
        let rotated = await session.affineSelection(inside: rotationRegion, scale: 1, rotation: .pi / 4); XCTAssertTrue(rotated)
        XCTAssertEqual(session.page?.elements?.first?.rotation ?? 0, .pi / 4, accuracy: 0.001)
        session.isReadOnly = true
        let rejected = await session.affineSelection(inside: rotationRegion, scale: 1.5, rotation: 0); XCTAssertFalse(rejected)
        let reopened = EditorSession(store: store, noteID: id, preferences: preferences); await reopened.open(pageID)
        XCTAssertEqual(reopened.page?.elements?.first?.rotation ?? 0, .pi / 4, accuracy: 0.001)
    }

    func testLockedImageCannotMoveOrResizeThroughLegacyHandles() {
        var item = PageElement(kind: .image, x: 50, y: 50, width: 100, height: 100)
        item.isLocked = true
        let view = ImageHandlesView(item: item, image: nil); view.pageSize = CGSize(width: 500, height: 500)
        view.moveImage(by: CGPoint(x: 30, y: 30)); view.resizeImage(by: 2); view.resizeSide(5, by: 40)
        XCTAssertEqual(view.item, item)
    }

    func testEllipseAndLineSelectionRejectBoundingBoxCorners() {
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        let ellipse = PageElement(kind: .ellipse, x: 100, y: 100, width: 100, height: 100)
        page.elements = [ellipse]
        let corner = UIBezierPath(rect: CGRect(x: 100, y: 100, width: 8, height: 8))
        XCTAssertTrue(DocumentClipboard.selectedElements(page, inside: corner, settings: EditorToolSettings()).isEmpty)
        let center = UIBezierPath(rect: CGRect(x: 145, y: 145, width: 8, height: 8))
        XCTAssertEqual(DocumentClipboard.selectedElements(page, inside: center, settings: EditorToolSettings()).count, 1)
        page.elements = [PageElement(kind: .line, x: 100, y: 100, width: 100, height: 100)]
        let offLine = UIBezierPath(rect: CGRect(x: 100, y: 190, width: 8, height: 8))
        XCTAssertTrue(DocumentClipboard.selectedElements(page, inside: offLine, settings: EditorToolSettings()).isEmpty)
    }
    func testElementOrderingUsesSharedRendererForScreenAndCapture() throws {
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        var note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 100, height: 100, text: "")
        note.fillColorHex = "#FF0000"; note.zIndex = 2
        var shape = PageElement(kind: .rectangle, x: 100, y: 100, width: 100, height: 100)
        shape.fillColorHex = "#0000FF"; shape.zIndex = 1
        page.elements = [note, shape]
        func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return rgba
        }
        let screen = PageRenderer.image(page, data: nil, scale: 1)
        let screenshot = try PageRenderer.capture(page, data: nil, drawing: InkDrawing(), resources: [:], rect: CGRect(x: 100, y: 100, width: 100, height: 100))
        let screenPixel = try pixel(screen, at: CGPoint(x: 150, y: 150))
        let capturePixel = try pixel(screenshot, at: CGPoint(x: 100, y: 100))
        XCTAssertGreaterThan(screenPixel[0], 240); XCTAssertLessThan(screenPixel[2], 10)
        XCTAssertGreaterThan(capturePixel[0], 240); XCTAssertLessThan(capturePixel[2], 10)
        page.elements?[0].zIndex = 0
        let reordered = try pixel(PageRenderer.image(page, data: nil, scale: 1), at: CGPoint(x: 150, y: 150))
        XCTAssertGreaterThan(reordered[2], 240); XCTAssertLessThan(reordered[0], 10)
    }

}
