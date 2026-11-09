import XCTest
import SwiftUI
import UIKit
@testable import OpenNotes

@MainActor
final class RedesignTests: XCTestCase {
    func testInstrumentPreferencesMigrateAndRestoreIndependently() async throws {
        let suite = "OpenNotes.instrument-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(6.0, forKey: "inkWidth")
        defaults.set(try NSKeyedArchiver.archivedData(withRootObject: UIColor.red, requiringSecureCoding: true), forKey: "inkColor")
        let store = LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await store.load()
        let id = UUID()
        let session = EditorSession(store: store, noteID: id, preferences: defaults)
        XCTAssertEqual(session.inkWidth, 6)
        XCTAssertEqual(UIColor(session.inkColor).presetHex, UIColor.red.presetHex)
        session.inkWidth = 2; session.inkColor = .blue
        session.selectedTool = .marker; session.inkWidth = 4; session.inkColor = .yellow
        session.selectedTool = .eraser
        session.selectedTool = .pen
        XCTAssertEqual(session.inkWidth, 2)
        XCTAssertEqual(UIColor(session.inkColor).presetHex, UIColor(Color.blue).presetHex)
        session.selectedTool = .marker
        XCTAssertEqual(session.inkWidth, 4)
        XCTAssertEqual(try XCTUnwrap(session.tool as? InkInkingTool).width, 16, accuracy: 0.001)
        let reopened = EditorSession(store: store, noteID: id, preferences: defaults)
        XCTAssertEqual(reopened.selectedTool, .marker)
        XCTAssertEqual(reopened.inkWidth, 4)
        reopened.selectedTool = .pen
        XCTAssertEqual(reopened.inkWidth, 2)
        XCTAssertEqual(defaults.double(forKey: "inkWidth"), 4, "Restoring a tool must not overwrite legacy preferences")
        defaults.removeObject(forKey: "instrumentPresets")
        defaults.set("marker", forKey: "inkTool"); defaults.set(12.0, forKey: "inkWidth")
        let wideMarker = EditorSession(store: store, noteID: id, preferences: defaults)
        XCTAssertEqual(wideMarker.inkWidth, 12, "Also preserve legacy highlighters above 32 engine points")
        XCTAssertEqual(try XCTUnwrap(wideMarker.tool as? InkInkingTool).width, 48, accuracy: 0.001)
    }
    func testInkMetadataDoesNotInvalidatePaperOrRecreateControls() {
        var page = NotePage(noteID: UUID(), index: 0, format: .a4Portrait, template: .grid, drawingResourceID: "ink.drawing")
        page.elements = [PageElement(kind: .image, resource: "photo.png"), PageElement(kind: .stickyNote, text: "Note")]
        let artwork = PageArtwork(page: page, data: nil, resources: [:])
        let view = PageScrollView(canvas: InkCanvasView()); view.pageSize = PageRenderer.size(page)
        view.paper.configure(page: page, artwork: artwork)
        view.configureImages(page, images: [:], pencil: false) { _, _ in }
        view.configureNotes(page, edit: nil) { _, _ in }
        let image = view.subviews.first { $0 is ImageHandlesView }
        let note = view.subviews.first { $0 is StickyNoteControl }
        for revision in 1...100 {
            page.drawingRevision = revision; page.revision = revision; page.bookmark = revision.isMultiple(of: 2)
            view.paper.configure(page: page, artwork: artwork)
            view.configureImages(page, images: [:], pencil: false) { _, _ in }
            view.configureNotes(page, edit: nil) { _, _ in }
        }
        XCTAssertEqual(view.paper.invalidationCount, 1)
        XCTAssertTrue(image === view.subviews.first { $0 is ImageHandlesView })
        XCTAssertTrue(note === view.subviews.first { $0 is StickyNoteControl })
        page.template = .dotted; view.paper.configure(page: page, artwork: artwork)
        XCTAssertEqual(view.paper.invalidationCount, 2)
    }
    func testPreviewResolutionsAndResourceInvalidation() async throws {
        let store = LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await store.load(); let created = await store.create(); let id = try XCTUnwrap(created)
        let page = try XCTUnwrap(store.library.firstPage(in: id))
        let small = try await store.disk.thumbnail(page)
        let cover = try await store.disk.thumbnail(page, pixels: 640)
        let transition = try await store.disk.thumbnail(page, pixels: 1400)
        XCTAssertLessThanOrEqual(max(small.size.width, small.size.height), 161)
        XCTAssertEqual(max(cover.size.width, cover.size.height), 640, accuracy: 1)
        XCTAssertEqual(max(transition.size.width, transition.size.height), 1400, accuracy: 1)
        XCTAssertEqual(transition.scale, 1)
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 400, y: 600)].enumerated().map { index, point in
            InkStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let ink = InkDrawing(strokes: [InkStroke(ink: InkInk(.pen, color: .red), path: InkStrokePath(controlPoints: points, creationDate: Date()))])
        try await store.disk.write(ink.dataRepresentation(), name: page.drawingResourceID)
        let updated = try await store.disk.thumbnail(page, pixels: 1400)
        XCTAssertNotEqual(transition.pngData(), updated.pngData())
    }
    func testBookmarkRefreshReusesVisualAssets() async throws {
        let store = LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await store.load(); let created = await store.create(); let id = try XCTUnwrap(created)
        let session = EditorSession(store: store, noteID: id); await session.open()
        let assets = try XCTUnwrap(session.artwork), page = try XCTUnwrap(session.page)
        let saved = await session.apply(.init(pageID: page.id, kind: .setBookmark, bookmark: true))
        XCTAssertTrue(saved); XCTAssertTrue(assets === session.artwork)
    }
    func testPreparedPageNavigationStillSavesAndRejectsFailedWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root); await store.load()
        let created = await store.create(); let id = try XCTUnwrap(created)
        let first = try XCTUnwrap(store.library.firstPage(in: id))
        let added = await store.addPage(noteID: id, after: first.id); let second = try XCTUnwrap(added)
        let session = EditorSession(store: store, noteID: id); await session.open(first.id)
        session.preparePage(second)
        let point = InkStrokePoint(location: CGPoint(x: 50, y: 60), timeOffset: 0, size: CGSize(width: 5, height: 5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        session.changed(InkDrawing(strokes: [InkStroke(ink: InkInk(.pen, color: .black), path: InkStrokePath(controlPoints: [point], creationDate: Date()))]))
        let folder = root.appendingPathComponent("resources"), backup = root.appendingPathComponent("safe-resources")
        try FileManager.default.moveItem(at: folder, to: backup); try Data().write(to: folder)
        await session.open(second)
        XCTAssertEqual(session.page?.id, first.id); XCTAssertTrue(session.dirty); XCTAssertEqual(session.drawing.strokes.count, 1)
        try FileManager.default.removeItem(at: folder); try FileManager.default.moveItem(at: backup, to: folder)
        await session.open(second)
        XCTAssertEqual(session.page?.id, second)
        await session.open(first.id)
        XCTAssertEqual(session.drawing.strokes.count, 1)
    }

    func testTransitionWaitsForInstalledCanvasAndRecoversFromFailure() async throws {
        let view = PageScrollView(canvas: InkCanvasView())
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 600); view.pageSize = CGSize(width: 794, height: 1123); view.layoutIfNeeded()
        let turn = view.pageTurn; turn.canNext = true
        var completion: CheckedContinuation<Bool, Never>?
        view.onNavigate = { _ in await withCheckedContinuation { completion = $0 } }
        func start() {
            let pan = RedesignPan(); pan.phase = .began; pan.offset = CGPoint(x: -10, y: 0); turn.drag(pan)
            pan.phase = .ended; pan.offset = CGPoint(x: -200, y: 0); turn.drag(pan)
        }
        start()
        for _ in 0..<100 { if completion != nil { break }; await Task.yield() }
        XCTAssertTrue(turn.committing)
        try XCTUnwrap(completion).resume(returning: true); completion = nil
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(turn.committing, "Success alone must not uncover an uninstalled canvas")
        let installed = UUID()
        turn.pageInstalled(installed)
        XCTAssertTrue(turn.committing, "Installed canvas must remain covered until its paper is drawn")
        turn.paperReady(installed)
        XCTAssertFalse(turn.committing)
        start()
        for _ in 0..<100 { if completion != nil { break }; await Task.yield() }
        try XCTUnwrap(completion).resume(returning: false)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(turn.committing)
        XCTAssertTrue(turn.shouldBegin(velocity: CGPoint(x: -200, y: 0)))
    }

}

private final class RedesignPan: UIPanGestureRecognizer {
    var phase = UIGestureRecognizer.State.possible
    var offset = CGPoint.zero
    override var state: UIGestureRecognizer.State { get { phase } set { phase = newValue } }
    override func translation(in view: UIView?) -> CGPoint { offset }
    override func velocity(in view: UIView?) -> CGPoint { .zero }
}
