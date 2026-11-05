import XCTest
import SwiftUI
import UIKit
@testable import OpenNotes

@MainActor
final class NativeInkIntegrationTests: XCTestCase {
    private func stroke(_ points: [CGPoint], color: UIColor = .blue, width: Double = 4) -> InkStroke {
        let samples = points.enumerated().map { index, point in
            InkStrokePoint(location: point, timeOffset: Double(index) / 120,
                           size: CGSize(width: width, height: width), opacity: 1,
                           force: 0.2 + CGFloat(index) / CGFloat(max(1, points.count)) * 0.6,
                           azimuth: 0.3, altitude: 1)
        }
        return InkStroke(ink: InkInk(.pen, color: color),
                         path: InkStrokePath(controlPoints: samples, creationDate: Date(timeIntervalSinceReferenceDate: 100)),
                         style: InkStyle(width: width))
    }

    func testSessionPartialEraseUndoRedoShapeAndReopenPreserveExactSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "native-ink-integration-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        await store.load()
        let created = await store.create()
        let noteID = try XCTUnwrap(created)
        let editor = EditorSession(store: store, noteID: noteID, preferences: preferences)
        await editor.open()
        XCTAssertNil(editor.error)
        let page = try XCTUnwrap(editor.page)
        editor.canvas.drawing = editor.drawing
        let undo = try XCTUnwrap(editor.canvas.undoManager)
        undo.groupsByEvent = false
        func commit(_ drawing: InkDrawing, _ action: String) {
            undo.beginUndoGrouping()
            editor.replaceDrawing(drawing, actionName: action)
            undo.endUndoGrouping()
        }

        let line = stroke([CGPoint(x: 10, y: 50), CGPoint(x: 150, y: 50)])
        let dot = stroke([CGPoint(x: 80, y: 25)])
        let inserted = InkDrawing(strokes: [line, dot])
        let insertedBytes = try inserted.encodedData()
        commit(inserted, "Draw")
        let erased = EraserEditing.erase(editor.drawing, along: [CGPoint(x: 80, y: 40), CGPoint(x: 80, y: 60)], width: 10, mode: .pixel)
        let erasedBytes = try erased.encodedData()
        XCTAssertEqual(erased.strokes.count, 3)
        XCTAssertEqual(erased.strokes.last?.id, dot.id)
        commit(erased, "Scribble to erase")
        undo.undo()
        XCTAssertEqual(try editor.drawing.encodedData(), insertedBytes)
        undo.redo()
        XCTAssertEqual(try editor.drawing.encodedData(), erasedBytes)
        XCTAssertEqual(editor.drawing.strokes.map(\.id), erased.strokes.map(\.id))

        let rawShape = stroke([CGPoint(x: 20, y: 110), CGPoint(x: 60, y: 111), CGPoint(x: 120, y: 110)])
        let shape = try XCTUnwrap(StrokeProcessing.process(rawShape, tool: .pen, width: 4,
                                                          settings: EditorToolSettings(), shapeHeld: true))
        XCTAssertEqual(shape.path.count, 2)
        XCTAssertEqual(shape.rawSamples, rawShape.rawSamples)
        let withShape = InkDrawing(strokes: erased.strokes + [shape])
        let shapeBytes = try withShape.encodedData()
        commit(withShape, "Draw shape")
        undo.undo()
        XCTAssertEqual(try editor.drawing.encodedData(), erasedBytes)
        undo.redo()
        XCTAssertEqual(try editor.drawing.encodedData(), shapeBytes)

        editor.setInkColor(.red)
        editor.toolSettings.penStyle = .brush
        editor.toolSettings.inkPattern = .dotted
        editor.toolSettings.tipSharpness = 0.8
        XCTAssertEqual(try editor.drawing.encodedData(), shapeBytes, "Preference edits must never restyle stored ink")
        let tool = try XCTUnwrap(editor.tool as? InkInkingTool)
        var redSource = stroke([CGPoint(x: 20, y: 150), CGPoint(x: 120, y: 155)], color: tool.color)
        redSource.ink = InkInk(tool.inkType, color: tool.color)
        let red = try XCTUnwrap(StrokeProcessing.process(redSource, tool: .pen, width: editor.documentInkWidth,
                                                       settings: editor.toolSettings, shapeHeld: false))
        commit(InkDrawing(strokes: editor.drawing.strokes + [red]), "Draw")
        let finalBytes = try editor.drawing.encodedData()
        XCTAssertEqual(editor.drawing.strokes[0].style, erased.strokes[0].style)
        XCTAssertEqual(editor.drawing.strokes.last?.style?.kind, .brush)
        XCTAssertEqual(editor.drawing.strokes.last?.style?.pattern, .dotted)
        XCTAssertTrue(editor.drawing.strokes.last!.ink.color.isEqual(tool.color))
        let saved = await editor.flush()
        XCTAssertTrue(saved)
        XCTAssertNil(editor.error)
        let committedResource = try XCTUnwrap(store.library.page(id: page.id)?.drawingResourceID)
        let persisted = try await store.disk.read(committedResource)
        XCTAssertEqual(persisted, finalBytes)

        let reopenedStore = LibraryStore(root: root)
        await reopenedStore.load()
        let reopened = EditorSession(store: reopenedStore, noteID: noteID, preferences: preferences)
        await reopened.open(page.id)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(try reopened.drawing.encodedData(), finalBytes)
        XCTAssertEqual(reopened.drawing.strokes.map(\.id), editor.drawing.strokes.map(\.id))
        let rect = CGRect(x: 0, y: 0, width: 180, height: 180)
        XCTAssertEqual(reopened.drawing.image(from: rect, scale: 2).pngData(), editor.drawing.image(from: rect, scale: 2).pngData())

        var invalid = editor.drawing
        invalid.strokes[0].rawSamples[0].location.x = .nan
        XCTAssertThrowsError(try invalid.encodedData())
        editor.changed(invalid)
        let invalidSaved = await editor.flush()
        XCTAssertFalse(invalidSaved)
        XCTAssertNotNil(editor.error)
        XCTAssertTrue(editor.dirty)
        let intact = try await store.disk.read(committedResource)
        XCTAssertEqual(intact, finalBytes, "Failed encoding must never overwrite the last valid page")
    }

    func testSyntheticThousandAndTenThousandStrokeDiagnostics() throws {
        var reports: [String] = []
        for count in [1_000, 10_000] {
            let strokes = (0..<count).map { index in
                let x = CGFloat(index % 100) * 8 + 4, y = CGFloat(index / 100) * 8 + 4
                return stroke([CGPoint(x: x, y: y), CGPoint(x: x + 4, y: y + 2)], width: 2)
            }
            let drawing = InkDrawing(strokes: strokes)
            let start = ProcessInfo.processInfo.systemUptime
            let bytes = try drawing.encodedData()
            let encoded = ProcessInfo.processInfo.systemUptime
            let reopened = try InkDrawing(data: bytes)
            let decoded = ProcessInfo.processInfo.systemUptime
            let image = reopened.image(from: CGRect(x: 0, y: 0, width: 256, height: 256), scale: 1)
            let rendered = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(reopened.strokes.count, count)
            XCTAssertEqual(reopened.strokes.first?.id, strokes.first?.id)
            XCTAssertEqual(reopened.strokes.last?.id, strokes.last?.id)
            XCTAssertFalse(bytes.isEmpty)
            XCTAssertNotNil(image.cgImage)
            let report = "Synthetic \(count) strokes: \(bytes.count) bytes; encode \(Int((encoded - start) * 1000)) ms; decode \(Int((decoded - encoded) * 1000)) ms; 256pt viewport render \(Int((rendered - decoded) * 1000)) ms. Environment: \(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)."
            reports.append(report)
            print(report)
        }
        let attachment = XCTAttachment(string: reports.joined(separator: "\n"))
        attachment.name = "Native ink synthetic serialization and viewport diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCircleOnlyBecomesEligibleAfterStoredStrokeAndExpiresWithoutDeletingInk() throws {
        let store = LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let noteID = UUID()
        let suite = "native-circle-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let editor = EditorSession(store: store, noteID: noteID, preferences: preferences)
        editor.page = NotePage(noteID: noteID, index: 0, format: .a4Portrait, template: .blank, drawingResourceID: "circle.ink")
        let coordinator = WritingCanvas.Coordinator(session: editor, zoomWindow: false)
        coordinator.pageID = editor.page?.id
        let circle = stroke((0...64).map { index in
            let angle = CGFloat(index) * .pi * 2 / 64
            return CGPoint(x: 100 + 50 * cos(angle), y: 100 + 50 * sin(angle))
        })
        var markerCircle = circle
        markerCircle.ink = InkInk(.marker, color: .yellow)
        XCTAssertNil(coordinator.completed(markerCircle))
        XCTAssertNil(coordinator.circle, "Highlighter gestures must not create pen lasso candidates")
        XCTAssertNil(coordinator.completed(circle))
        XCTAssertFalse(coordinator.canSelectCircle(at: CGPoint(x: 150, y: 100)), "A candidate cannot select before the circle is committed")
        editor.drawing = InkDrawing(strokes: [circle])
        let original = try editor.drawing.encodedData()
        XCTAssertTrue(coordinator.canSelectCircle(at: CGPoint(x: 150, y: 100)))
        XCTAssertFalse(coordinator.canSelectCircle(at: CGPoint(x: 100, y: 100)))
        XCTAssertEqual(try editor.drawing.encodedData(), original, "Recognizing a circle must not remove it at pen-up")
        coordinator.circle?.expires = 0
        XCTAssertFalse(coordinator.canSelectCircle(at: CGPoint(x: 150, y: 100)))
        XCTAssertEqual(try editor.drawing.encodedData(), original)
    }
}
