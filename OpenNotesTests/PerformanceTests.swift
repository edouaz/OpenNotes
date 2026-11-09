import XCTest
import UIKit
@testable import OpenNotes

// Reproducible benchmarks on dense generated pages. They print `PERF <name> median=<ms>` lines and assert
// correctness only (timings vary by device). Run on an iPad in Release for real numbers:
//   xcodebuild test -scheme OpenNotes -destination 'platform=iOS,name=<iPad>' -only-testing:OpenNotesTests/PerformanceTests -configuration Release
// For Instruments, profile the app with the "os_signpost" template (subsystem fr.opennotes, category perf).
@MainActor
final class PerformanceTests: XCTestCase {
    static let pageSize = CGSize(width: 794, height: 1123)

    /// Handwriting-like page: `lines` text lines of `strokesPerLine` strokes, `samples` points each (~0.5 pt apart, like coalesced Pencil input).
    static func handwriting(lines: Int = 30, strokesPerLine: Int = 10, samples: Int = 80) -> InkDrawing {
        var strokes: [InkStroke] = []
        for line in 0..<lines {
            for index in 0..<strokesPerLine {
                strokes.append(stroke(samples: samples, origin: CGPoint(x: 40 + CGFloat(index) * 70, y: 60 + CGFloat(line) * 34), seed: line * 31 + index))
            }
        }
        return InkDrawing(strokes: strokes)
    }
    static func stroke(samples: Int, origin: CGPoint, seed: Int, step: CGFloat = 0.5, width: CGFloat = 3) -> InkStroke {
        let points = (0..<samples).map { i -> InkStrokePoint in
            let t = CGFloat(i) * step
            return InkStrokePoint(location: CGPoint(x: origin.x + t * 0.8 + sin(t / 6 + CGFloat(seed)) * 6, y: origin.y + cos(t / 5 + CGFloat(seed)) * 8),
                                  timeOffset: Double(i) * 0.004, size: CGSize(width: width, height: width), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return InkStroke(ink: InkInk(.pen, color: .black), path: InkStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
    }
    func page(noteID: UUID = UUID(), pdfIndex: Int? = nil, background: String? = nil) -> NotePage {
        var page = NotePage(noteID: noteID, index: 0, format: .a4Portrait, template: .ruled, drawingResourceID: "drawing")
        page.width = Self.pageSize.width; page.height = Self.pageSize.height
        page.pdfIndex = pdfIndex; page.backgroundID = background
        return page
    }
    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    @discardableResult func bench(_ name: String, runs: Int = 5, _ body: () throws -> Void) rethrows -> Double {
        try body() // warm-up: caches, lazy paths
        var times: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try body()
            times.append(Self.ms(ContinuousClock.now - start))
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: "PERF %@ median=%.2f ms", name, median))
        return median
    }

    // MARK: eraser
    func testEraserSweepsOnDensePage() {
        let drawing = Self.handwriting()
        let sweep = (0..<40).map { CGPoint(x: 100 + CGFloat($0) * 8, y: 300 + sin(CGFloat($0) / 4) * 20) }
        for mode in [EditorToolSettings.EraserMode.standard, .stroke, .precision] {
            bench("eraser.\(mode).dense300strokes") {
                XCTAssertFalse(EraserEditing.erase(drawing, along: sweep, width: 20, mode: mode).strokes.isEmpty)
            }
        }
    }
    func testEraserOnLongStroke() {
        for samples in [1_000, 3_000] {
            let drawing = InkDrawing(strokes: [Self.stroke(samples: samples, origin: CGPoint(x: 40, y: 400), seed: 1, step: 0.25)])
            let sweep = [CGPoint(x: 150, y: 400), CGPoint(x: 170, y: 405)]
            for mode in [EditorToolSettings.EraserMode.standard, .precision] {
                bench("eraser.\(mode).longstroke\(samples)", runs: 3) {
                    _ = EraserEditing.erase(drawing, along: sweep, width: 16, mode: mode)
                }
            }
        }
    }

    // MARK: lasso
    func testLassoSnapshotOnDensePage() {
        let drawing = Self.handwriting()
        let page = page()
        let lasso = UIBezierPath(rect: CGRect(x: 0, y: 0, width: Self.pageSize.width, height: 560))
        var settings = EditorToolSettings(); settings.includeHandwriting = true
        bench("lasso.snapshot.dense300strokes") {
            let snapshot = SelectionMoveSnapshot(page: page, drawing: drawing, path: lasso, settings: settings)
            XCTAssertFalse(snapshot.strokeIndices.isEmpty)
        }
    }

    // A real lasso has hundreds of edges and pages have notes: a rectangle alone hides most of the snapshot cost.
    func testLassoSnapshotWithFreeformEdgesAndNotes() {
        let drawing = Self.handwriting()
        let page = page()
        let settings = EditorToolSettings()
        for edges in [100, 400, 1_200] {
            let lasso = UIBezierPath()
            for index in 0..<edges {
                let angle = CGFloat(index) / CGFloat(edges) * 2 * .pi, wobble = 1 + 0.08 * sin(angle * 9)
                let point = CGPoint(x: 397 + cos(angle) * 380 * wobble, y: 300 + sin(angle) * 280 * wobble)
                if index == 0 { lasso.move(to: point) } else { lasso.addLine(to: point) }
            }
            lasso.close()
            bench("lasso.snapshot.freeform\(edges)edges.dense300strokes") {
                XCTAssertFalse(SelectionMoveSnapshot(page: page, drawing: drawing, path: lasso, settings: settings).strokeIndices.isEmpty)
            }
        }
        var noted = page
        noted.elements = (0..<5).map { PageElement(kind: .stickyNote, x: 40 + Double($0) * 140, y: 100 + Double($0) * 120, width: 180, height: 160) }
        let everything = UIBezierPath(rect: CGRect(origin: .zero, size: Self.pageSize))
        bench("lasso.snapshot.5notes.dense300strokes", runs: 3) { _ = SelectionMoveSnapshot(page: noted, drawing: drawing, path: everything, settings: settings) }
        let inner = UIBezierPath(rect: CGRect(x: 60, y: 60, width: 200, height: 100))
        bench("lasso.snapshot.5notes.smallLasso.dense300strokes", runs: 3) { _ = SelectionMoveSnapshot(page: noted, drawing: drawing, path: inner, settings: settings) }
    }
    func testPickupPreviews() {
        let drawing = Self.handwriting()
        let viewport = CGRect(x: 0, y: 0, width: 1194, height: 834)
        var noted = page()
        let note = PageElement(kind: .stickyNote, x: 100, y: 100, width: 300, height: 300)
        noted.elements = [note]
        let artwork = PageArtwork(page: noted, data: nil, resources: [:])
        let lasso = SelectionMoveSnapshot(page: page(), drawing: drawing, path: UIBezierPath(rect: CGRect(x: 40, y: 50, width: 300, height: 200)), settings: EditorToolSettings())
        bench("lasso.pickup.dense300strokes", runs: 3) {
            _ = SelectionDragPreview(frame: viewport, page: page(), artwork: artwork, drawing: drawing, snapshot: lasso, zoom: 1, offset: .zero)
        }
        var settings = EditorToolSettings(); settings.includeHandwriting = false
        let sticky = SelectionMoveSnapshot(page: noted, drawing: drawing, path: UIBezierPath(rect: note.visibleBounds), settings: settings)
        bench("sticky.pickup.dense300strokes", runs: 3) {
            _ = SelectionDragPreview(frame: viewport, page: noted, artwork: artwork, drawing: drawing, snapshot: sticky, zoom: 1, offset: .zero)
        }
    }

    // MARK: persistence
    func testDrawingEncodeDecode() throws {
        let drawing = Self.handwriting()
        var data = Data()
        bench("drawing.encode.dense300strokes") { data = try! drawing.encodedData() }
        bench("drawing.decode.dense300strokes") { XCTAssertEqual(try! InkDrawing(data: data).strokes.count, drawing.strokes.count) }
        print("PERF drawing.size.dense300strokes bytes=\(data.count) samples=\(drawing.strokes.reduce(0) { $0 + $1.path.count })")
    }
    func testAutosaveOfLibraryWithIndexedPDFText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DiskStore(root: root)
        var home = NotebookFolder(id: NotebookFolder.homeID, name: "Home")
        var library = NoteLibrarySnapshot()
        let text = String(repeating: "lorem ipsum dolor sit amet ", count: 150) // ~4 KB per page, like an indexed PDF page
        for n in 0..<20 {
            var note = NoteDocument(folderID: home.id, title: "PDF \(n)")
            for p in 0..<50 {
                var page = NotePage(noteID: note.id, index: p, format: .a4Portrait, template: .blank, drawingResourceID: "d-\(n)-\(p)")
                page.pdfText = PageTextContent(source: .pdf, status: .available, text: text, blocks: [])
                library.pages.append(page); note.pageIDs.append(page.id)
                try await store.write(Data("{}".utf8), name: page.drawingResourceID)
            }
            home.noteIDs.append(note.id); library.notes.append(note)
        }
        library.folders = [home]
        try await store.save(library) // first save also writes the text sidecar; time the steady state after it
        let start = ContinuousClock.now
        for i in 0..<5 { library.pages[0].modifiedAt = Date(timeIntervalSinceNow: Double(i + 1)); try await store.save(library) }
        let ms = Self.ms(ContinuousClock.now - start) / 5
        print(String(format: "PERF disk.save.20pdfs1000pages median~%.2f ms (library.json %d bytes)", ms, (try? Data(contentsOf: root.appendingPathComponent("library.json")).count) ?? 0))
    }

    // MARK: render + PDF
    func testRenderAndPDFOpen() throws {
        let drawing = Self.handwriting()
        let blank = page()
        bench("render.image.dense300strokes.scale1", runs: 3) { _ = PageRenderer.image(blank, data: nil, drawing: drawing, scale: 1) }
        bench("render.image.dense300strokes.scale2", runs: 3) { _ = PageRenderer.image(blank, data: nil, drawing: drawing, scale: 2) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).writePDF(to: url) { context in
            for p in 0..<200 {
                context.beginPage()
                for line in 0..<40 { ("Page \(p) line \(line) lorem ipsum dolor sit amet" as NSString).draw(at: CGPoint(x: 30, y: 20 + CGFloat(line) * 18), withAttributes: [.font: UIFont.systemFont(ofSize: 11)]) }
            }
        }
        let data = try Data(contentsOf: url)
        print("PERF pdf.fixture bytes=\(data.count) pages=200")
        let pdfPage = page(pdfIndex: 150, background: "pdf")
        bench("pdf.open.artwork.200pages", runs: 3) { XCTAssertNotNil(PageArtwork(page: pdfPage, data: data, resources: [:]).pdfPage) }
        let artwork = PageArtwork(page: pdfPage, data: data, resources: [:])
        bench("render.image.pdfpage.reusedArtwork", runs: 3) { _ = PageRenderer.image(pdfPage, data: data, drawing: drawing, pdfPage: artwork.pdfPage, images: artwork.images, scale: 2) }
    }
}
