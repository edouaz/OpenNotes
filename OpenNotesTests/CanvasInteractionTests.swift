import XCTest
import UIKit
import PDFKit
import SwiftUI
@testable import OpenNotes

@MainActor
final class CanvasInteractionTests: XCTestCase {
    private func evidence(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func page() -> NotePage {
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "ink.drawing")
        page.width = 300; page.height = 200
        return page
    }
    private func stroke(_ locations: [CGPoint], type: InkInk.InkType = .pen, width: CGFloat = 8) -> InkStroke {
        let points = locations.enumerated().map { index, point in
            InkStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: width, height: width), opacity: 1, force: CGFloat(index + 1) / CGFloat(locations.count), azimuth: 0.4, altitude: 1)
        }
        return InkStroke(ink: InkInk(type, color: type == .marker ? .yellow : .black), path: InkStrokePath(controlPoints: points, creationDate: Date()))
    }
    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let offset = (y * source.width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }
    func testImageSelectionSurvivesUpdatesAndFreeTapEndsOnlyOnce() throws {
        var page = page()
        page.elements = [PageElement(kind: .image, resource: "one.png"), PageElement(kind: .image, resource: "two.png")]
        let view = PageScrollView(canvas: InkCanvasView()); view.pageSize = PageRenderer.size(page)
        view.configureImages(page, images: [:], pencil: false) { _, _ in }
        var images = view.subviews.compactMap { $0 as? ImageHandlesView }
        XCTAssertTrue(images.allSatisfy { !$0.showsHandles })
        view.configureImages(page, images: [:], pencil: true) { _, _ in }
        XCTAssertEqual(images.filter(\.showsHandles).map { $0.item.id }, [try XCTUnwrap(page.elements?.last?.id)])
        view.deselectImages()
        view.configureImages(page, images: [:], pencil: true) { _, _ in }
        XCTAssertTrue(images.allSatisfy { !$0.showsHandles }, "A SwiftUI update must not reopen dismissed handles")
        var new = PageElement(kind: .image); new.resource = "three.png"
        page.elements?.append(new)
        view.configureImages(page, images: [:], pencil: true) { _, _ in }
        images = view.subviews.compactMap { $0 as? ImageHandlesView }
        XCTAssertEqual(images.filter(\.showsHandles).map { $0.item.id }, [new.id])
        let active = try XCTUnwrap(images.first { $0.showsHandles })
        active.frame = CGRect(x: 10, y: 30, width: 200, height: 100); active.layoutIfNeeded()
        XCTAssertEqual(active.deleteButton.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(active.subviews.filter { $0.gestureRecognizers?.contains(where: { $0 is UIPanGestureRecognizer }) == true }.count, 8)
        XCTAssertTrue(active.subviews.filter { $0.gestureRecognizers?.contains(where: { $0 is UIPanGestureRecognizer }) == true }.allSatisfy { $0.bounds.size == CGSize(width: 44, height: 44) })
    }
    func testPencilOnlySelectionRoutesFingerBodyToCanvasButKeepsHandles() throws {
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        view.pageSize = CGSize(width: 400, height: 400); view.layoutIfNeeded()
        view.configureSelection(true, immediate: false, selected: nil)
        let selection = try XCTUnwrap(view.subviews.compactMap { $0 as? PageSelectionView }.first)
        selection.installSelection(UIBezierPath(rect: CGRect(x: 80, y: 80, width: 160, height: 160)))
        selection.showsResizeHandles = true
        view.fingerScrollsSelection = true
        let body = CGPoint(x: 150, y: 150)
        let routed = view.hitTest(body, with: nil)
        XCTAssertTrue(routed === view.canvas || routed?.isDescendant(of: view.canvas) == true)
        XCTAssertTrue(selection.activeGestures.allSatisfy { $0.view === view })
        XCTAssertTrue(selection.activeGestures.filter { $0 is UIPanGestureRecognizer || $0 is UITapGestureRecognizer }.allSatisfy { $0.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.pencil.rawValue)] })
        let corner = view.hitTest(CGPoint(x: 80, y: 80), with: nil)
        XCTAssertTrue(corner?.isDescendant(of: selection) == true && corner !== selection)
        view.fingerScrollsSelection = false
        XCTAssertTrue(view.hitTest(body, with: nil) === selection)
        XCTAssertTrue(selection.activeGestures.allSatisfy { $0.view === selection })
        view.configureSelection(false, immediate: false, selected: nil)
        XCTAssertTrue(selection.activeGestures.allSatisfy { $0.view == nil })
    }

    func testIdleImageDoesNotInterceptCanvasPan() throws {
        var page = page()
        page.elements = [PageElement(kind: .image, x: 30, y: 30, width: 120, height: 80)]
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        view.pageSize = PageRenderer.size(page); view.layoutIfNeeded()
        var activated: UUID?
        view.configureImages(page, images: [:], pencil: false, beginEditing: { activated = $0 }) { _, _ in }
        let image = try XCTUnwrap(view.subviews.compactMap { $0 as? ImageHandlesView }.first)
        let hit = view.hitTest(image.center, with: nil)
        XCTAssertTrue(hit === view.canvas || hit?.isDescendant(of: view.canvas) == true)
        XCTAssertTrue(image.accessibilityActivate())
        XCTAssertEqual(activated, image.item.id)
    }

    func testImageDeleteRemainsVisibleAtViewportOriginWithoutCoveringCorner() throws {
        let viewport = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let image = ImageHandlesView(item: PageElement(kind: .image), image: nil)
        image.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        viewport.addSubview(image); image.layoutIfNeeded()
        XCTAssertTrue(viewport.bounds.contains(image.convert(image.deleteButton.frame, to: viewport)))
        let corner = try XCTUnwrap(image.subviews.first { $0.tag == 0 && $0.gestureRecognizers?.contains(where: { $0 is UIPanGestureRecognizer }) == true })
        XCTAssertFalse(corner.frame.intersects(image.deleteButton.frame))
        XCTAssertTrue(image.hitTest(.zero, with: nil) === corner)
    }

    func testImageSidesResizeOneAxisAndKeepOppositeEdge() {
        for side in 4...7 {
            let image = ImageHandlesView(item: PageElement(kind: .image, x: 100, y: 100, width: 200, height: 100), image: nil)
            image.pageSize = CGSize(width: 1000, height: 1000); image.zoom = 2
            image.resizeSide(side, by: 30)
            if side < 6 { XCTAssertEqual(image.item.height, 100); XCTAssertEqual(image.item.y, 100) }
            else { XCTAssertEqual(image.item.width, 200); XCTAssertEqual(image.item.x, 100) }
            if side == 4 { XCTAssertEqual(image.item.x + image.item.width, 300) }
            if side == 6 { XCTAssertEqual(image.item.y + image.item.height, 200) }
        }
    }
    func testImageDragTakesCenterTouchesWithoutWaitingForUnrelatedResizeHandles() {
        let image = ImageHandlesView(item: PageElement(kind: .image, x: 100, y: 100, width: 200, height: 100), image: nil)
        image.frame = CGRect(x: 100, y: 100, width: 200, height: 100); image.layoutIfNeeded()
        image.showsHandles = true
        XCTAssertTrue(image.acceptsImageDrag(at: CGPoint(x: 100, y: 50)))
        XCTAssertFalse(image.acceptsImageDrag(at: .zero))
        XCTAssertFalse(image.acceptsImageDrag(at: CGPoint(x: 200, y: 50)))
        XCTAssertFalse(image.acceptsImageDrag(at: CGPoint(x: -28, y: -28)))
        image.showsHandles = false
        XCTAssertTrue(image.acceptsImageDrag(at: .zero))
    }
    func testStickyCollapseAndResizeKeepTextAndPersist() throws {
        let note = StickyNoteControl(item: PageElement(kind: .stickyNote, x: 20, y: 20, width: 120, height: 100, text: "Keep this text"))
        note.pageSize = CGSize(width: 300, height: 200)
        note.resizeNote(to: CGSize(width: 180, height: 120))
        note.toggleCollapsed()
        let restored = try JSONDecoder().decode(PageElement.self, from: JSONEncoder().encode(note.item))
        XCTAssertEqual(restored.text, "Keep this text"); XCTAssertTrue(restored.collapsed == true)
        XCTAssertEqual(restored.width, 180); XCTAssertEqual(restored.height, 120)
        note.toggleCollapsed()
        XCTAssertFalse(note.item.collapsed == true); XCTAssertEqual(note.item.width, 180)
    }
    func testCollapsedStickyUsesVisibleBoundsForLassoAndCapture() throws {
        var page = page()
        page.elements = [PageElement(kind: .stickyNote, x: 20, y: 20, width: 180, height: 100, text: "Conserver", collapsed: true)]
        let hidden = UIBezierPath(rect: CGRect(x: 100, y: 80, width: 30, height: 20))
        XCTAssertTrue(DocumentClipboard.selectedElements(page, inside: hidden, settings: EditorToolSettings()).isEmpty)
        let visible = UIBezierPath(rect: CGRect(x: 20, y: 20, width: 44, height: 44))
        XCTAssertEqual(DocumentClipboard.selectedElements(page, inside: visible, settings: EditorToolSettings()).count, 1)
        XCTAssertLessThan(try pixel(PageRenderer.image(page, data: nil), x: 60, y: 40)[2], 200)
    }
    func testLassoFiltersAreIndependentAndCaptureWorksWithoutInk() throws {
        var page = page()
        let image = PageElement(kind: .image, x: 30, y: 30, width: 60, height: 60, resource: "one.png")
        let sticky = PageElement(kind: .stickyNote, x: 130, y: 30, width: 100, height: 100, text: "Note")
        page.elements = [image, sticky]
        let path = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 260, height: 160))
        var settings = EditorToolSettings(); settings.includeHandwriting = false
        XCTAssertEqual(DocumentClipboard.selectedElements(page, inside: path, settings: settings).count, 2)
        settings.includeImages = false
        XCTAssertEqual(DocumentClipboard.selectedElements(page, inside: path, settings: settings).map(\.id), [sticky.id])
        settings.includeImages = true; settings.includeStickyNotes = false
        XCTAssertEqual(DocumentClipboard.selectedElements(page, inside: path, settings: settings).map(\.id), [image.id])
        let captured = try PageRenderer.capture(page, data: nil, drawing: InkDrawing(), resources: [:], rect: path.bounds, path: path)
        XCTAssertGreaterThan(try pixel(captured, x: 140, y: 80)[3], 0)
    }
    func testFreeCaptureClipsOutsideContourAndLeavesDocumentIntact() throws {
        let page = page(), encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(page)
        let path = UIBezierPath(); path.move(to: CGPoint(x: 20, y: 20)); path.addLine(to: CGPoint(x: 120, y: 70)); path.addLine(to: CGPoint(x: 20, y: 120)); path.close()
        let image = try PageRenderer.capture(page, data: nil, drawing: InkDrawing(), resources: [:], rect: path.bounds, path: path)
        XCTAssertEqual(try pixel(image, x: 180, y: 10)[3], 0)
        XCTAssertEqual(try pixel(image, x: 10, y: 100)[3], 255)
        XCTAssertEqual(try encoder.encode(page), original)
        evidence(image, "Freeform capture — transparent exterior")
    }
    func testPenProfilesAndStabilizationChangeEditableStrokeData() throws {
        let source = stroke([CGPoint(x: 10, y: 80), CGPoint(x: 40, y: 50), CGPoint(x: 70, y: 110), CGPoint(x: 100, y: 50), CGPoint(x: 130, y: 80)])
        var settings = EditorToolSettings()
        let ball = try XCTUnwrap(StrokeProcessing.process(source, tool: .pen, width: 8, settings: settings, shapeHeld: false))
        XCTAssertTrue(ball.path.allSatisfy { $0.size == CGSize(width: 8, height: 8) })
        settings.penStyle = .fountain
        let fountain = try XCTUnwrap(StrokeProcessing.process(source, tool: .pen, width: 8, settings: settings, shapeHeld: false))
        XCTAssertEqual(fountain.path[2].size.height, fountain.path[2].size.width)
        XCTAssertGreaterThan(fountain.path.last!.size.width, fountain.path.first!.size.width)
        settings.penStyle = .brush
        let brush = try XCTUnwrap(StrokeProcessing.process(source, tool: .pen, width: 8, settings: settings, shapeHeld: false))
        XCTAssertGreaterThan(brush.path[2].size.width, brush.path[0].size.width)
        settings.stabilization = 100
        let smooth = try XCTUnwrap(StrokeProcessing.process(source, tool: .pen, width: 8, settings: settings, shapeHeld: false))
        XCTAssertLessThan(abs(smooth.path[2].location.y - 80), abs(source.path[2].location.y - 80))
        XCTAssertEqual(smooth.path.first?.location, source.path.first?.location)
        XCTAssertNoThrow(try InkDrawing(data: InkDrawing(strokes: [smooth]).dataRepresentation()))
        for (name, ink) in [("Ballpoint", ball), ("Fountain", fountain), ("Brush", brush), ("Stabilization 100 percent", smooth)] {
            evidence(PageRenderer.image(page(), data: nil, drawing: InkDrawing(strokes: [ink])), "Synthetic profile — \(name)")
        }
    }
    func testHoldShapeRequiresEnabledOptionAndWorksForMarker() throws {
        let source = stroke([CGPoint(x: 20, y: 100), CGPoint(x: 80, y: 102), CGPoint(x: 160, y: 100)], type: .marker)
        var settings = EditorToolSettings()
        let freehand = try XCTUnwrap(StrokeProcessing.process(source, tool: .marker, width: 8, settings: settings, shapeHeld: false))
        XCTAssertEqual(freehand.path.map(\.location), source.path.map(\.location))
        let shape = try XCTUnwrap(StrokeProcessing.process(source, tool: .marker, width: 8, settings: settings, shapeHeld: true))
        XCTAssertEqual(shape.ink.inkType, .marker)
        XCTAssertEqual(shape.path.map(\.location), [source.path.first!.location, source.path.last!.location])
        settings.shapeRecognitionEnabled = false
        let disabled = try XCTUnwrap(StrokeProcessing.process(source, tool: .marker, width: 8, settings: settings, shapeHeld: true))
        XCTAssertEqual(disabled.path.map(\.location), source.path.map(\.location))
    }
    func testPDFMarkerComposesBelowOpaqueTextInImageCaptureAndExport() throws {
        var page = page(); page.backgroundID = "source.pdf"; page.pdfIndex = 0
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 200)).pdfData { context in
            context.beginPage(); UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            UIColor.black.setFill(); context.fill(CGRect(x: 80, y: 75, width: 60, height: 50))
            ("PDF" as NSString).draw(at: CGPoint(x: 175, y: 85), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.black])
        }
        let drawing = InkDrawing(strokes: [stroke([CGPoint(x: 20, y: 100), CGPoint(x: 280, y: 100)], type: .marker, width: 50)])
        let rendered = PageRenderer.image(page, data: pdf, drawing: drawing)
        evidence(rendered, "Highlighter composited below PDF text")
        let black = try pixel(rendered, x: 110, y: 100)
        XCTAssertLessThan(black[0], 3); XCTAssertLessThan(black[1], 3); XCTAssertLessThan(black[2], 3)
        XCTAssertLessThan(try pixel(rendered, x: 50, y: 100)[2], 240, "The marker must remain visible on the PDF paper")
        let cropped = try PageRenderer.capture(page, data: pdf, drawing: drawing, resources: [:], rect: CGRect(x: 80, y: 75, width: 60, height: 50))
        XCTAssertLessThan(try pixel(cropped, x: 60, y: 50)[1], 3)
        let note = NoteDocument(id: page.noteID, folderID: UUID(), title: "PDF", pageIDs: [page.id])
        let archive = NotebookArchive(note: note, pages: [page], resources: ["source.pdf": pdf, "ink.drawing": drawing.dataRepresentation()])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PageRenderer.export(archive, indices: 0...0, output: url)
        let exported = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        XCTAssertTrue(exported.string?.contains("PDF") == true, "The underlying PDF text remains vector and searchable")
        let image = exported.thumbnail(of: CGSize(width: 300, height: 200), for: .mediaBox)
        XCTAssertLessThan(try pixel(image, x: 110, y: 100)[1], 3)
        evidence(image, "PDF export — highlighted black text")
        let attachment = XCTAttachment(data: try Data(contentsOf: url), uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "Searchable vector PDF export"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testFilteredSelectionUndoRedoAndReopenPreserveImagesAndStickyNotes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try XCTUnwrap(UserDefaults(suiteName: directory.lastPathComponent))
        defer { preferences.removePersistentDomain(forName: directory.lastPathComponent) }
        let store = LibraryStore(root: directory); await store.load()
        let created = await store.create(); let id = try XCTUnwrap(created)
        let session = EditorSession(store: store, noteID: id, preferences: preferences); await session.open()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50)).image { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 50)) }
        await session.insertImage(image)
        let sticky = PageElement(kind: .stickyNote, x: 30, y: 40, width: 180, height: 100, text: "Conserver", collapsed: true)
        let pageID = try XCTUnwrap(session.page?.id)
        let applied = await session.apply(.init(pageID: pageID, kind: .upsertElement, element: sticky)); XCTAssertTrue(applied)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = UIScreen.main.bounds
        window.rootViewController = UIHostingController(rootView: WritingCanvas(session: session, finger: false, reading: false)); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        let undo = try XCTUnwrap(session.canvas.undoManager); undo.removeAllActions()
        session.toolSettings.includeHandwriting = false; session.toolSettings.includeImages = true; session.toolSettings.includeStickyNotes = false
        let original = try XCTUnwrap(session.page?.elements?.first { $0.kind == .image })
        let moved = await session.moveSelection(inside: UIBezierPath(rect: CGRect(origin: .zero, size: PageRenderer.size(try XCTUnwrap(session.page)))), by: CGPoint(x: 10, y: 20))
        XCTAssertTrue(moved)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(session.page?.elements?.first { $0.kind == .image }?.x, original.x + 10)
        XCTAssertEqual(session.page?.elements?.first { $0.id == sticky.id }, sticky)
        undo.undo()
        XCTAssertEqual(session.page?.elements?.first { $0.kind == .image }?.x, original.x)
        XCTAssertTrue(undo.canRedo); undo.redo()
        XCTAssertEqual(session.page?.elements?.first { $0.kind == .image }?.x, original.x + 10)
        let saved = await session.flush(); XCTAssertTrue(saved)
        let reopened = EditorSession(store: store, noteID: id, preferences: preferences); await reopened.open(pageID)
        XCTAssertEqual(reopened.page?.elements?.first { $0.kind == .image }?.x, original.x + 10)
        XCTAssertEqual(reopened.page?.elements?.first { $0.id == sticky.id }, sticky)
        XCTAssertNotNil(reopened.page?.elements?.first { $0.kind == .image }?.resource.flatMap { reopened.resources[$0] })
    }






    func testLassoIgnoresErasedHolesAndSelectsIntersectingImageEdges() {
        let ink = InkDrawing(strokes: [stroke([CGPoint(x: 20, y: 100), CGPoint(x: 280, y: 100)])])
        let erased = EraserEditing.erase(ink, along: [CGPoint(x: 150, y: 90), CGPoint(x: 150, y: 110)], width: 50, mode: .pixel)
        XCTAssertTrue(DocumentClipboard.selectedInk(erased, inside: UIBezierPath(rect: CGRect(x: 145, y: 95, width: 10, height: 10))).strokes.isEmpty)
        var page = page(); let image = PageElement(kind: .image, x: 80, y: 50, width: 60, height: 100, resource: "one.png"); page.elements = [image]
        let acrossEdge = UIBezierPath(rect: CGRect(x: 0, y: 65, width: 250, height: 5))
        XCTAssertEqual(DocumentClipboard.selectedElements(page, inside: acrossEdge, settings: EditorToolSettings()).map(\.id), [image.id])
    }
}
