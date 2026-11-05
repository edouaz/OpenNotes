import XCTest
import SwiftUI
import UIKit
@testable import OpenNotes

@MainActor
final class PolishTests: XCTestCase {
    private func makeStore() async -> LibraryStore {
        let store = LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await store.load(); return store
    }
    private func stroke() -> InkDrawing {
        let points = [CGPoint(x: 30, y: 40), CGPoint(x: 190, y: 240)].enumerated().map { i, p in
            InkStrokePoint(location: p, timeOffset: Double(i), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return InkDrawing(strokes: [InkStroke(ink: InkInk(.pen, color: .black), path: InkStrokePath(controlPoints: points, creationDate: Date()))])
    }
    func testShareStagingIsAtomicPreservesNamesAndCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = root.appendingPathComponent("queue")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("My course.pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)).pdfData { $0.beginPage() }
        try data.write(to: source)
        try ShareInbox.stage(source, in: queue)
        let pending = try ShareInbox.staged(in: queue)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.lastPathComponent, "My course.pdf")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(pending.first)), data)
        XCTAssertEqual(try ShareInbox.staged(in: queue), pending)
        try ShareInbox.remove(XCTUnwrap(pending.first))
        XCTAssertTrue(try ShareInbox.staged(in: queue).isEmpty)
        let invalid = root.appendingPathComponent("bad.exe"); try data.write(to: invalid)
        XCTAssertThrowsError(try ShareInbox.stage(invalid, in: queue))
        XCTAssertTrue(try ShareInbox.staged(in: queue).isEmpty)
    }
    func testImageDownsamplingKeepsAspectRatio() throws {
        let original = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 2000), format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }()).image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 2000)) }
        let image = try ImportedImage.decode(XCTUnwrap(original.pngData()))
        XCTAssertEqual(image.size.width, 3200, accuracy: 1)
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.001)
        XCTAssertThrowsError(try ImportedImage.decode(Data("invalid".utf8)))
        let (cropped, size) = try ImportedImage.encode(image, crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(size.width, 1600, accuracy: 1); XCTAssertEqual(size.height, 800, accuracy: 1)
        XCTAssertNotNil(UIImage(data: cropped))
        XCTAssertThrowsError(try ImportedImage.encode(image, crop: CGRect(x: -1, y: 0, width: 1, height: 1)))
    }
    func testImageHandlesPreserveRatioAndPageBounds() {
        let item = PageElement(kind: .image, x: 60, y: 120, width: 220, height: 120)
        let view = ImageHandlesView(item: item, image: nil)
        view.pageSize = CGSize(width: 500, height: 700)
        var result: PageElement?
        view.changed = { result = $0 }
        view.resizeImage(by: 10)
        XCTAssertEqual(view.item.width / view.item.height, 220 / 120, accuracy: 0.001)
        XCTAssertLessThanOrEqual(view.item.width + view.item.x, 500)
        view.moveImage(by: CGPoint(x: -1000, y: 1000))
        XCTAssertEqual(view.item.x, 0)
        XCTAssertLessThanOrEqual(view.item.y + view.item.height, 700)
        XCTAssertEqual(result, view.item)
    }
    func testPagingOnlyUsesSelectedAxisAtFitZoom() {
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        view.pageSize = CGSize(width: 794, height: 1123); view.layoutIfNeeded()
        XCTAssertTrue(view.pageTurn.shouldBegin(velocity: CGPoint(x: -200, y: 0)))
        XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: 0, y: -200)))
        view.verticalPaging = true
        XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: -200, y: 0)))
        XCTAssertTrue(view.pageTurn.shouldBegin(velocity: CGPoint(x: 0, y: -200)))
        view.canvas.setZoomScale(2, animated: false)
        XCTAssertFalse(view.pageTurn.shouldBegin(velocity: CGPoint(x: 0, y: -200)))
        view.fingerDrawing = true
        XCTAssertEqual(view.pageTurn.gesture.minimumNumberOfTouches, 2)
        XCTAssertEqual(view.pageTurn.gesture.maximumNumberOfTouches, 2)
        view.fingerDrawing = false
        XCTAssertEqual(view.pageTurn.gesture.minimumNumberOfTouches, 1)
        XCTAssertFalse(InteractivePageTurn.shouldCommit(progress: 0.3, speed: 900, hasPage: false, canCreate: true))
        XCTAssertTrue(InteractivePageTurn.shouldCommit(progress: 0.7, speed: 0, hasPage: false, canCreate: true))
        XCTAssertFalse(InteractivePageTurn.shouldCommit(progress: 0.9, speed: 0, hasPage: false, canCreate: false))
    }
    func testCustomCanvasIgnoresLegacyNativePalettePreferenceAndKeepsUndo() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "nativeTools")
        defaults.set(true, forKey: "nativeTools")
        defer { if let previous { defaults.set(previous, forKey: "nativeTools") } else { defaults.removeObject(forKey: "nativeTools") } }
        let store = await makeStore(); let created = await store.create(); let id = try XCTUnwrap(created)
        let session = EditorSession(store: store, noteID: id); await session.open()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = UIScreen.main.bounds
        let host = UIHostingController(rootView: WritingCanvas(session: session, finger: false, reading: false))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 150_000_000)
        session.canvas.drawing = stroke()
        let before = session.canvas.drawing.dataRepresentation()
        let undo = try XCTUnwrap(session.canvas.undoManager)
        undo.registerUndo(withTarget: session.canvas) { canvas in canvas.drawing = InkDrawing() }
        session.selectedTool = .marker
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual((session.canvas.tool as? InkInkingTool)?.inkType, .marker)
        XCTAssertEqual(session.canvas.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(session.canvas.drawing.dataRepresentation(), before)
        XCTAssertTrue(session.canvas.undoManager === undo)
        XCTAssertTrue(undo.canUndo)
        undo.undo(); XCTAssertTrue(session.canvas.drawing.strokes.isEmpty)
    }
    func testUndoAvailabilityFollowsNativeHistoryAndPageChanges() async throws {
        let store = await makeStore(); let created = await store.create(); let id = try XCTUnwrap(created)
        let session = EditorSession(store: store, noteID: id); await session.open()
        let first = try XCTUnwrap(session.page)
        let added = await store.addPage(noteID: id, after: first.id); let next = try XCTUnwrap(added)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = UIScreen.main.bounds
        window.rootViewController = UIHostingController(rootView: WritingCanvas(session: session, finger: false, reading: false))
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 {
            if session.canvas.isFirstResponder { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let undo = try XCTUnwrap(session.canvas.undoManager)
        let coordinator = try XCTUnwrap(session.canvas.delegate as? WritingCanvas.Coordinator)
        let groupedByEvent = undo.groupsByEvent
        undo.groupsByEvent = false; undo.removeAllActions()
        defer { undo.removeAllActions(); undo.groupsByEvent = groupedByEvent }
        coordinator.updateUndoAvailability()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(session.canUndo); XCTAssertFalse(session.canRedo)

        let value = NSMutableString(string: "original")
        func changeValue(_ text: String) {
            let previous = value.description
            undo.registerUndo(withTarget: value) { _ in changeValue(previous) }
            value.setString(text)
        }
        undo.beginUndoGrouping(); changeValue("modified"); undo.endUndoGrouping()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(session.canUndo); XCTAssertFalse(session.canRedo)
        undo.undo()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(value.description, "original")
        XCTAssertFalse(session.canUndo); XCTAssertTrue(session.canRedo)
        undo.redo()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(value.description, "modified")
        XCTAssertTrue(session.canUndo); XCTAssertFalse(session.canRedo)

        await session.open(next)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(undo.canUndo); XCTAssertFalse(undo.canRedo)
        XCTAssertFalse(session.canUndo); XCTAssertFalse(session.canRedo)
    }
    func testCanvasFocusRecoversAfterPresentationAndDoesNotReactivateWhenDetached() async throws {
        let store = await makeStore(); let created = await store.create(); let id = try XCTUnwrap(created)
        let session = EditorSession(store: store, noteID: id); await session.open()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = UIScreen.main.bounds
        let host = UIHostingController(rootView: WritingCanvas(session: session, finger: false, reading: false))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<100 {
            if session.canvas.isFirstResponder { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(session.canvas.isFirstResponder)
        let coordinator = try XCTUnwrap(session.canvas.delegate as? WritingCanvas.Coordinator)
        session.canvas.resignFirstResponder()
        coordinator.updateInteraction()
        XCTAssertFalse(session.canvas.isFirstResponder, "Focus must not change in the calling transaction")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(session.canvas.isFirstResponder)
        session.canvas.resignFirstResponder()
        coordinator.updateInteraction()
        WritingCanvas.dismantleUIView(try XCTUnwrap(coordinator.container), coordinator: coordinator)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(session.canvas.isFirstResponder, "Pending activation must not reclaim focus after teardown")
        XCTAssertEqual(coordinator.activeCanvas.overrideUserInterfaceStyle, .light)
    }
    func testLatestPageRequestWinsAndSavesInk() async throws {
        let store = await makeStore()
        let created = await store.create(); let id = try XCTUnwrap(created)
        let first = try XCTUnwrap(store.library.firstPage(in: id))
        let secondID = await store.addPage(noteID: id, after: first.id)
        let second = try XCTUnwrap(secondID)
        let thirdID = await store.addPage(noteID: id, after: second)
        let third = try XCTUnwrap(thirdID)
        let session = EditorSession(store: store, noteID: id); await session.open(first.id)
        session.changed(stroke())
        let b = Task { await session.open(second) }
        let c = Task { await session.open(third) }
        await b.value; await c.value
        XCTAssertEqual(session.page?.id, third)
        let bytes = try await store.disk.read(try XCTUnwrap(store.library.page(id: first.id)?.drawingResourceID))
        XCTAssertEqual(try InkDrawing(data: XCTUnwrap(bytes)).strokes.count, 1)
        XCTAssertFalse(session.busy)
    }
    func testFailedDrawingWriteIsRetriedWithoutLosingInk() async throws {
        let store = await makeStore()
        let created = await store.create(); let id = try XCTUnwrap(created)
        let session = EditorSession(store: store, noteID: id); await session.open()
        let page = try XCTUnwrap(session.page)
        let folder = await store.disk.root.appendingPathComponent("resources")
        let moved = folder.deletingLastPathComponent().appendingPathComponent("saved-resources")
        try FileManager.default.moveItem(at: folder, to: moved)
        try Data("blocked".utf8).write(to: folder)
        session.changed(stroke())
        let failed = await session.flush(); XCTAssertFalse(failed); XCTAssertTrue(session.dirty)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: moved, to: folder)
        let saved = await session.flush(); XCTAssertTrue(saved)
        let bytes = try await store.disk.read(try XCTUnwrap(store.library.page(id: page.id)?.drawingResourceID))
        XCTAssertEqual(try InkDrawing(data: XCTUnwrap(bytes)).strokes.count, 1)
    }
    func testTabsPreserveSessionsAndClosingSaves() async throws {
        let store = await makeStore()
        let aID = await store.create(title: "A"), bID = await store.create(title: "B")
        let a = try XCTUnwrap(aID), b = try XCTUnwrap(bID)
        let model = NotebookWorkspace(store: store)
        await model.select(a)
        let session = model.session(a); await session.open(); session.changed(stroke())
        let page = try XCTUnwrap(session.page)
        await model.select(b); await model.select(a)
        XCTAssertEqual(model.tabs, [a, b]); XCTAssertTrue(model.session(a) === session)
        await model.close(a)
        XCTAssertEqual(model.active, b); XCTAssertEqual(model.tabs, [b])
        let bytes = try await store.disk.read(try XCTUnwrap(store.library.page(id: page.id)?.drawingResourceID))
        XCTAssertEqual(try InkDrawing(data: XCTUnwrap(bytes)).strokes.count, 1)
        XCTAssertNotNil(store.library.note(id: a))
        await model.close(b)
    }
    func testViewportSurvivesResizeAndReopenAndDoubleTapFits() throws {
        let canvas = InkCanvasView(), id = UUID(), note = UUID()
        let view = PageScrollView(canvas: canvas)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600); view.pageSize = CGSize(width: 794, height: 1123)
        view.restorePosition(id, noteID: note); view.layoutIfNeeded()
        canvas.setZoomScale(2, animated: false); canvas.contentOffset = CGPoint(x: 120, y: 180)
        view.savePosition()
        let center = CGPoint(x: (canvas.contentOffset.x + 200) / 2, y: (canvas.contentOffset.y + 300) / 2)
        view.frame.size = CGSize(width: 600, height: 400); view.layoutIfNeeded()
        XCTAssertEqual(canvas.zoomScale, 2, accuracy: 0.01)
        XCTAssertEqual((canvas.contentOffset.x + 300) / 2, center.x, accuracy: 1)
        XCTAssertEqual((canvas.contentOffset.y + 200) / 2, center.y, accuracy: 1)
        let reopened = PageScrollView(canvas: InkCanvasView())
        reopened.frame = CGRect(x: 0, y: 0, width: 400, height: 600); reopened.pageSize = view.pageSize
        reopened.restorePosition(id, noteID: note); reopened.layoutIfNeeded()
        XCTAssertEqual(reopened.canvas.zoomScale, 2, accuracy: 0.01)
        reopened.fitPage()
        XCTAssertEqual(reopened.canvas.zoomScale, reopened.canvas.minimumZoomScale, accuracy: 0.01)
    }
    func testCustomToolSelectionLeavesInkUntouched() async throws {
        let store = await makeStore(); let created = await store.create(); let id = try XCTUnwrap(created)
        let session = EditorSession(store: store, noteID: id); await session.open()
        session.canvas.drawing = stroke()
        let before = session.canvas.drawing.dataRepresentation()
        session.selectedTool = .marker; session.inkWidth = 6; session.setInkColor(.red)
        XCTAssertEqual(session.selectedTool, .marker); XCTAssertEqual(session.inkWidth, 6)
        session.selectedTool = .eraser; XCTAssertEqual(session.selectedTool, .eraser)
        XCTAssertEqual(session.canvas.drawing.dataRepresentation(), before)
    }
    func testThumbnailInvalidationAndRangeExportAndImportReceipts() async throws {
        let store = await makeStore(); let created = await store.create(); let id = try XCTUnwrap(created)
        let page = try XCTUnwrap(store.library.firstPage(in: id))
        let empty = try await store.disk.thumbnail(page)
        XCTAssertEqual(empty.scale, 1, "Thumbnails must have a valid UIKit scale on iOS 16")
        let pixels = try XCTUnwrap(empty.cgImage)
        XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), 161)
        XCTAssertEqual(empty.size.width, CGFloat(pixels.width))
        XCTAssertEqual(empty.size.height, CGFloat(pixels.height))
        XCTAssertNotNil(empty.imageAsset, "SwiftUI stores the preview in UIImageAsset")
        try await store.disk.write(stroke().dataRepresentation(), name: page.drawingResourceID)
        let inked = try await store.disk.thumbnail(page)
        XCTAssertNotEqual(empty.pngData(), inked.pngData())
        let disk = store.disk
        let concurrent = try await withThrowingTaskGroup(of: UIImage.self) { group in
            for _ in 0..<12 { group.addTask { try await disk.thumbnail(page) } }
            var count = 0
            for try await image in group { XCTAssertGreaterThan(image.size.width, 0); count += 1 }
            return count
        }
        XCTAssertEqual(concurrent, 12)
        let second = await store.addPage(noteID: id, after: page.id)
        XCTAssertNotNil(second)
        let range = try await store.archive(id, indices: 1...1)
        XCTAssertEqual(range.pages.count, 1); XCTAssertEqual(range.note.pageIDs, range.pages.map(\.id))
        XCTAssertNoThrow(try range.validate())
        store.library.sharedImports["receipt.pdf"] = id; store.persist()
        let saved = await store.flush(); XCTAssertTrue(saved)
        let loaded = try await store.disk.load()
        XCTAssertEqual(loaded.sharedImports["receipt.pdf"], id)
    }
}
