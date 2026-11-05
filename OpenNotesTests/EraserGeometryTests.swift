import XCTest
import UIKit
@testable import OpenNotes

@MainActor
final class EraserGeometryTests: XCTestCase {
    private func line(width: CGFloat = 40, kind: InkInk.InkType = .pen) -> InkStroke {
        let points = [CGPoint(x: 20, y: 100), CGPoint(x: 220, y: 100)].enumerated().map {
            InkStrokePoint(location: $0.element, timeOffset: Double($0.offset), size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return InkStroke(ink: InkInk(kind, color: .black), path: InkStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
    }
    func testPrecisionPreservesLateralInkAndRoundTripsWithoutRestoringHole() throws {
        let source = line()
        let erased = EraserEditing.erase(InkDrawing(strokes: [source]), along: [CGPoint(x: 100, y: 100)], width: 10, mode: .precision)
        let stroke = try XCTUnwrap(erased.strokes.first)
        XCTAssertEqual(stroke.id, source.id)
        XCTAssertFalse(stroke.paintedPath.contains(CGPoint(x: 100, y: 100)))
        XCTAssertTrue(stroke.paintedPath.contains(CGPoint(x: 100, y: 115)))
        XCTAssertEqual(stroke.rawSamples, source.rawSamples)
        let bytes = try erased.encodedData()
        let reopened = try InkDrawing(data: bytes)
        XCTAssertFalse(reopened.strokes[0].paintedPath.contains(CGPoint(x: 100, y: 100)))
        XCTAssertEqual(try reopened.encodedData(), bytes)
        let repeated = EraserEditing.erase(reopened, along: [CGPoint(x: 130, y: 100)], width: 10, mode: .precision)
        XCTAssertFalse(repeated.strokes[0].paintedPath.contains(CGPoint(x: 100, y: 100)))
        XCTAssertFalse(repeated.strokes[0].paintedPath.contains(CGPoint(x: 130, y: 100)))
    }
    func testChangedDetectsEveryEraseOutcomeWithoutEncoding() {
        let drawing = InkDrawing(strokes: [line()])
        XCTAssertFalse(EraserEditing.changed(drawing, drawing))
        for mode in [EditorToolSettings.EraserMode.stroke, .standard, .precision] {
            let erased = EraserEditing.erase(drawing, along: [CGPoint(x: 100, y: 100)], width: 10, mode: mode)
            XCTAssertTrue(EraserEditing.changed(erased, drawing), "\(mode)")
        }
        XCTAssertFalse(EraserEditing.changed(EraserEditing.erase(drawing, along: [CGPoint(x: 100, y: 900)], width: 10, mode: .precision), drawing))
    }
    func testModesFilterAndFastSweepAreDistinct() throws {
        let source = line()
        let drawing = InkDrawing(strokes: [source])
        let path = [CGPoint(x: 100, y: 30), CGPoint(x: 100, y: 170)]
        XCTAssertTrue(EraserEditing.erase(drawing, along: path, width: 10, mode: .stroke).strokes.isEmpty)
        let standard = EraserEditing.erase(drawing, along: path, width: 10, mode: .standard)
        XCTAssertEqual(standard.strokes.count, 2)
        let precision = EraserEditing.erase(drawing, along: path, width: 10, mode: .precision)
        XCTAssertEqual(precision.strokes.count, 1)
        XCTAssertFalse(precision.strokes[0].paintedPath.contains(CGPoint(x: 100, y: 100)))
        XCTAssertEqual(EraserEditing.erase(drawing, along: path, width: 10, mode: .stroke, erasePen: false).strokes.count, 1)
        let marker = InkDrawing(strokes: [line(kind: .marker)])
        XCTAssertEqual(EraserEditing.erase(marker, along: path, width: 10, mode: .stroke, eraseHighlighter: false).strokes.count, 1)
    }
    func testStrokeEraserHitsVisibleEdgeAndStationaryRepeatedSamples() throws {
        let source = line()
        let drawing = InkDrawing(strokes: [source])
        let sweep = [CGPoint(x: 50, y: 124), CGPoint(x: 150, y: 124)]
        XCTAssertTrue(EraserEditing.erase(drawing, along: sweep, width: 10, mode: .stroke).strokes.isEmpty)
        let point = CGPoint(x: 100, y: 100)
        XCTAssertTrue(EraserEditing.erase(drawing, along: [point, point], width: 10, mode: .stroke).strokes.isEmpty)
        XCTAssertEqual(EraserEditing.erase(drawing, along: [CGPoint(x: 100, y: 126)], width: 10, mode: .stroke).strokes.count, 1)
        let standard = EraserEditing.erase(drawing, along: [CGPoint(x: 100, y: 126)], width: 10, mode: .standard)
        XCTAssertNotEqual(try standard.encodedData(), try drawing.encodedData())
        XCTAssertTrue(standard.strokes.contains { $0.paintedPath.contains(CGPoint(x: 40, y: 100)) })
    }
    func testEraserCursorTracksPageCoordinatesAndClearsOnToolSwitchAndCancel() throws {
        let canvas = InkCanvasView()
        canvas.tool = InkEraserTool(.bitmap, width: 24)
        canvas.showToolCursor(at: CGPoint(x: 100, y: 80), width: 24, color: .label, fill: .white.withAlphaComponent(0.12))
        let layer = try XCTUnwrap(canvas.inkContentView.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.path?.boundingBox.midX == 100 })
        XCTAssertEqual(layer.path?.boundingBox, CGRect(x: 88, y: 68, width: 24, height: 24))
        XCTAssertFalse(layer.isHidden)
        XCTAssertEqual(try XCTUnwrap(layer.fillColor).alpha, 0.12, accuracy: 0.001)
        canvas.tool = InkInkingTool(.pen, color: .black, width: 3)
        XCTAssertTrue(layer.isHidden)
        canvas.showToolCursor(at: CGPoint(x: 120, y: 90), width: 24, color: .label)
        canvas.cancelActiveStroke()
        XCTAssertTrue(layer.isHidden)
    }
    func testPencilContactKeepsEraserCursorWhenHoverEndsInEveryMode() throws {
        let canvas = InkCanvasView()
        canvas.setPageSize(CGSize(width: 300, height: 300))
        canvas.selectedTool = .eraser
        canvas.tool = InkEraserTool(.vector, width: 24)
        for mode in [EditorToolSettings.EraserMode.stroke, .standard, .precision] {
            canvas.settings.eraserMode = mode
            let touch = CursorTouch()
            canvas.inkContentView.touchesBegan([touch], with: nil)
            XCTAssertTrue(canvas.hasActiveStroke)
            let layer = try XCTUnwrap(canvas.inkContentView.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.path?.boundingBox.midX == 100 })
            XCTAssertFalse(layer.isHidden, "Cursor at contact in \(mode)")
            XCTAssertEqual(layer.path?.boundingBox.width, mode == .standard ? 28 : 24)
            canvas.hovered(EndedHover())
            XCTAssertFalse(layer.isHidden, "Hover ending must not hide the contact cursor in \(mode)")
            canvas.inkContentView.touchesCancelled([touch], with: nil)
            XCTAssertTrue(layer.isHidden)
        }
    }
    func testStickyMasksUnrelatedInkButNotItsOwnInkInCanvasAndExport() throws {
        let note = PageElement(kind: .stickyNote, x: 20, y: 20, width: 60, height: 60)
        func stroke(y: CGFloat) -> InkStroke {
            let points = [CGPoint(x: 0, y: y), CGPoint(x: 100, y: y)].enumerated().map {
                InkStrokePoint(location: $0.element, timeOffset: Double($0.offset), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return InkStroke(ink: InkInk(.pen, color: .black), path: InkStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
        }
        let background = stroke(y: 30)
        var owned = stroke(y: 45); owned.parentID = note.id
        let drawing = InkDrawing(strokes: [background, owned])
        let original = try drawing.encodedData()
        let occlusion = StickyInkOcclusion([note])
        let clipped = try XCTUnwrap(occlusion.visible(background))
        XCTAssertFalse(clipped.paintedPath.contains(CGPoint(x: 50, y: 30)))
        XCTAssertTrue(clipped.paintedPath.contains(CGPoint(x: 10, y: 30)))
        XCTAssertTrue(try XCTUnwrap(occlusion.visible(owned)).paintedPath.contains(CGPoint(x: 50, y: 45)))
        let upper = PageElement(kind: .stickyNote, x: 40, y: 20, width: 30, height: 60)
        let partiallyCovered = try XCTUnwrap(StickyInkOcclusion([note, upper]).visible(owned))
        XCTAssertTrue(partiallyCovered.paintedPath.contains(CGPoint(x: 30, y: 45)))
        XCTAssertFalse(partiallyCovered.paintedPath.contains(CGPoint(x: 50, y: 45)))
        XCTAssertEqual(try drawing.encodedData(), original)

        let view = InkContentView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.setOccludingNotes([note]); view.install(drawing)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { view.layer.render(in: $0.cgContext) }
        func alpha(_ point: CGPoint) throws -> UInt8 {
            let pixelImage = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
            var pixel = [UInt8](repeating: 0, count: 4)
            return try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return bytes[3]
            }
        }
        XCTAssertLessThan(try alpha(CGPoint(x: 50, y: 30)), 10)
        XCTAssertGreaterThan(try alpha(CGPoint(x: 10, y: 30)), 200)
        XCTAssertGreaterThan(try alpha(CGPoint(x: 50, y: 45)), 200)
    }
    func testEraserPreservesInkHiddenByStickyEvenWhenSweepCrossesItsEdge() throws {
        let note = PageElement(kind: .stickyNote, x: 60, y: 70, width: 100, height: 60)
        let source = line(width: 4)
        let content = InkContentView()
        content.setOccludingNotes([note])
        for mode in [EditorToolSettings.EraserMode.precision, .standard, .pixel] {
            let hiddenOnly = content.eraseVisible([source], along: [CGPoint(x: 100, y: 100)], width: 10, mode: mode)
            XCTAssertEqual(try InkDrawing(strokes: hiddenOnly).encodedData(), try InkDrawing(strokes: [source]).encodedData())
            let crossing = content.eraseVisible([source], along: [CGPoint(x: 30, y: 100), CGPoint(x: 180, y: 100)], width: 10, mode: mode)
            XCTAssertTrue(crossing.contains { $0.paintedPath.contains(CGPoint(x: 100, y: 100)) }, "Hidden ink must survive \(mode)")
            XCTAssertFalse(crossing.contains { $0.paintedPath.contains(CGPoint(x: 40, y: 100)) }, "Visible ink must be erased in \(mode)")
        }
        let hiddenOnly = content.eraseVisible([source], along: [CGPoint(x: 100, y: 100)], width: 10, mode: .stroke)
        XCTAssertEqual(hiddenOnly.map(\.id), [source.id])
        XCTAssertTrue(content.eraseVisible([source], along: [CGPoint(x: 30, y: 100)], width: 10, mode: .stroke).isEmpty)
    }
    func testPrecisionLocalCoordinatesSurviveRotationAndStandardDoesNotRestoreMask() throws {
        var source = line()
        source.transform = CGAffineTransform(rotationAngle: .pi / 2).concatenating(CGAffineTransform(translationX: 200, y: 0))
        let result = EraserEditing.erase(InkDrawing(strokes: [source]), along: [CGPoint(x: 100, y: 100)], width: 10, mode: .precision)
        XCTAssertFalse(try XCTUnwrap(result.strokes.first).paintedPath.contains(CGPoint(x: 100, y: 100)))
        let split = EraserEditing.erase(result, along: [CGPoint(x: 100, y: 150)], width: 12, mode: .standard)
        XCTAssertFalse(split.strokes.contains { $0.paintedPath.contains(CGPoint(x: 100, y: 100)) })
    }
    func testSchemaOneBackupBeforeFirstWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = DiskStore(root: root)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: InkDrawing(strokes: [line()]).encodedData()) as? [String: Any])
        object["inkSchemaVersion"] = 1
        let old = try JSONSerialization.data(withJSONObject: object)
        try await disk.write(old, name: "old.drawing")
        let latest = try InkDrawing(data: old).encodedData()
        try await disk.write(latest, name: "old.drawing")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("ink-schema-backups/old.drawing")), old)
        let current = try await disk.read("old.drawing")
        XCTAssertEqual(current, latest)
    }
    func testSpatialIndexAndInvalidInput() throws {
        let stroke = line()
        let drawing = InkDrawing(strokes: [stroke])
        let index = InkSpatialIndex(drawing)
        XCTAssertTrue(index.query(CGRect(x: 100, y: 90, width: 10, height: 10)).contains(stroke.id))
        XCTAssertFalse(index.query(CGRect(x: 500, y: 500, width: 10, height: 10)).contains(stroke.id))
        XCTAssertEqual(try EraserEditing.erase(drawing, along: [CGPoint(x: CGFloat.nan, y: 0)], width: 10, mode: .precision).encodedData(), try drawing.encodedData())
    }
    func testLiveStepperMatchesFinalProcessingAndIncrementalOutlineMatchesFull() throws {
        var settings = EditorToolSettings(); settings.setStabilization(60, for: .pen)
        var samples: [InkStrokePoint] = []
        for i in 0..<40 {
            let x = CGFloat(10 + i * 3), y = CGFloat(50) + CGFloat(sin(Double(i) / 4) * 20)
            samples.append(InkStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3),
                                          opacity: 1, force: CGFloat(i % 7) / 7, azimuth: 0, altitude: .pi / 2))
        }
        let source = InkStroke(ink: InkInk(.pen, color: .black), path: InkStrokePath(controlPoints: samples, creationDate: Date(timeIntervalSince1970: 0)), rawSamples: samples)
        let full = try XCTUnwrap(StrokeProcessing.process(source, tool: .pen, width: 3, settings: settings, shapeHeld: false))
        var live = try XCTUnwrap(StrokeProcessing.Live(tool: .pen, width: 3, settings: settings))
        let outline = CGMutablePath(); var done = 0
        for (i, sample) in samples.enumerated() {
            live.append(sample)
            if i % 5 == 4 { InkStroke.addOutline(of: live.controls, from: done, to: outline); done = live.controls.count }
        }
        InkStroke.addOutline(of: live.controls, from: done, to: outline)
        XCTAssertEqual(live.controls, full.path.controlPoints)
        let whole = CGMutablePath(); InkStroke.addOutline(of: full.path.controlPoints, from: 0, to: whole)
        XCTAssertEqual(outline.boundingBoxOfPath, whole.boundingBoxOfPath)
        for point in full.path { XCTAssertEqual(outline.contains(point.location), whole.contains(point.location)) }
    }
    func testGeometryCachesInvalidateOnMutation() {
        var vector = InkVectorPath(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil))
        XCTAssertEqual(vector.cgPath.boundingBoxOfPath.width, 10)
        vector.elements = InkVectorPath(CGPath(rect: CGRect(x: 0, y: 0, width: 20, height: 10), transform: nil)).elements
        XCTAssertEqual(vector.cgPath.boundingBoxOfPath.width, 20)
        var stroke = line()
        let before = stroke.renderBounds
        XCTAssertEqual(stroke.paintedPath.boundingBoxOfPath.width, stroke.paintedPath.boundingBoxOfPath.width)
        stroke.path = InkStrokePath(controlPoints: Array(stroke.path.prefix(1)), creationDate: stroke.path.creationDate)
        XCTAssertNotEqual(stroke.renderBounds, before)
        stroke.vectorOutline = vector
        XCTAssertEqual(stroke.renderBounds.width, 20)
    }
    func testAutosavePrunesOldRevisionsButKeepsTheBackupGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = DiskStore(root: root)
        var library = NoteLibrarySnapshot(folders: [NotebookFolder(name: "F")])
        let note = try library.addNote(title: "N", folderID: library.folders[0].id)
        let pageID = library.pages(in: note.id)[0].id
        var names: [String] = []
        for _ in 0..<3 {
            let name = try await disk.writeDrawingRevision(Data("{}".utf8)); names.append(name)
            let index = try XCTUnwrap(library.pages.firstIndex { $0.id == pageID })
            library.pages[index].drawingResourceID = name
            try await disk.save(library)
        }
        let resources = root.appendingPathComponent("resources")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resources.appendingPathComponent(names[0]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent(names[1]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent(names[2]).path))
        // A fresh store (no memory of the last write) must still validate the file and keep the same generations.
        let reopened = DiskStore(root: root)
        let name = try await reopened.writeDrawingRevision(Data("{}".utf8))
        library.pages[0].drawingResourceID = name
        try await reopened.save(library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resources.appendingPathComponent(names[1]).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent(names[2]).path))
    }
}

@MainActor
private final class CursorTouch: UITouch {
    override var type: UITouch.TouchType { .pencil }
    override var timestamp: TimeInterval { 1 }
    override var altitudeAngle: CGFloat { .pi / 2 }
    override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 100, y: 80) }
}

@MainActor
private final class EndedHover: UIHoverGestureRecognizer {
    override var state: UIGestureRecognizer.State {
        get { .ended }
        set { }
    }
}
