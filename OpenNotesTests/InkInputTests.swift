import XCTest
import UIKit
@testable import OpenNotes

final class InkInputTests: XCTestCase {
    private func point(_ x: Double, time: Double, pressure: Double = 0.5) -> InkStrokePoint {
        InkStrokePoint(location: CGPoint(x: x, y: 20), timeOffset: time, size: CGSize(width: 3, height: 3),
                       opacity: 1, force: pressure, azimuth: 0, altitude: .pi / 2)
    }
    func testCoalescedTerminalDeduplicationAndEqualTimestampMeasurements() {
        var buffer = InkSampleBuffer()
        let terminal = point(30, time: 0.1)
        buffer.append(point(10, time: 0))
        buffer.append(terminal); buffer.append(terminal)
        buffer.append(point(31, time: 0.1))
        buffer.append(point(99, time: 0.05))
        XCTAssertEqual(buffer.samples.map(\.location.x), [10, 30, 31])
        XCTAssertEqual(buffer.samples.map(\.timeOffset), [0, 0.1, 0.1])
    }
    func testPredictionsAreReplacedAndNeverEnterMeasuredSamples() {
        var buffer = InkSampleBuffer()
        buffer.append(point(10, time: 0))
        buffer.predict([point(90, time: 0.1), point(100, time: 0.2)])
        buffer.predict([point(40, time: 0.1)])
        XCTAssertEqual(buffer.predictions.map(\.location.x), [40])
        XCTAssertEqual(buffer.samples.map(\.location.x), [10])
        buffer.clearPredictions()
        XCTAssertTrue(buffer.predictions.isEmpty)
        XCTAssertEqual(buffer.samples.count, 1)
    }
    func testEstimatedPropertiesReplaceOriginalSampleWithoutChangingChronology() {
        var buffer = InkSampleBuffer()
        buffer.append(point(10, time: 0, pressure: 0.2), estimate: 4)
        buffer.append(point(30, time: 0.1))
        XCTAssertTrue(buffer.update(point(11, time: 0.5, pressure: 0.8), estimate: 4))
        XCTAssertEqual(buffer.samples.count, 2)
        XCTAssertEqual(buffer.samples[0].force, 0.8)
        XCTAssertEqual(buffer.samples[0].location.x, 11)
        XCTAssertEqual(buffer.samples[0].timeOffset, 0)
        XCTAssertFalse(buffer.update(point(12, time: 0), estimate: 99))
    }
    func testCancelledInputClearsRawPredictedAndEstimatedSamples() {
        var buffer = InkSampleBuffer()
        buffer.append(point(10, time: 0), estimate: 1)
        buffer.predict([point(20, time: 0.1)])
        buffer.cancel()
        XCTAssertTrue(buffer.samples.isEmpty)
        XCTAssertTrue(buffer.predictions.isEmpty)
        XCTAssertFalse(buffer.update(point(11, time: 0), estimate: 1))
    }
    func testPreviewGeometryIncludesPredictionButRawSourceNeverDoes() throws {
        var buffer = InkSampleBuffer()
        buffer.append(point(10, time: 0)); buffer.append(point(20, time: 0.1))
        buffer.predict([point(35, time: 0.2)])
        let preview = try XCTUnwrap(buffer.stroke(geometry: buffer.samples + buffer.predictions,
            ink: InkInk(.pen, color: .black), createdAt: Date(), id: UUID(), tool: .pen, width: 3, settings: EditorToolSettings()))
        let predictedX = try XCTUnwrap(preview.path.last?.location.x)
        XCTAssertGreaterThan(predictedX, 20)
        XCTAssertLessThanOrEqual(predictedX, 35)
        XCTAssertEqual(preview.rawSamples.map(\.location.x), [10, 20])
        let held = try XCTUnwrap(buffer.stroke(geometry: [point(50, time: 0), point(100, time: 0.1)],
            ink: InkInk(.pen, color: .black), createdAt: Date(), id: UUID(), tool: .pen, width: 3, settings: EditorToolSettings()))
        XCTAssertEqual(held.path.first?.location.x, 50)
        XCTAssertGreaterThan(try XCTUnwrap(held.path.last?.location.x), 95)
        XCTAssertLessThanOrEqual(try XCTUnwrap(held.path.last?.location.x), 100)
        XCTAssertEqual(held.rawSamples.map(\.location.x), [10, 20])
        XCTAssertEqual(try InkDrawing(data: InkDrawing(strokes: [held]).dataRepresentation()).strokes[0].path.map(\.location.x), held.path.map(\.location.x))
    }
    @MainActor
    func testPencilOnlyRejectsFingerAndIndirectInput() {
        let canvas = InkCanvasView()
        XCTAssertTrue(canvas.accepts(.pencil))
        XCTAssertFalse(canvas.accepts(.direct))
        XCTAssertFalse(canvas.accepts(.indirect))
        canvas.drawingPolicy = .anyInput
        XCTAssertTrue(canvas.accepts(.direct))
        XCTAssertFalse(canvas.accepts(.indirect))
    }
    @MainActor
    func testPreviewAndCancellationDoNotMutateDocumentOrUndo() {
        let canvas = InkCanvasView()
        canvas.setPageSize(CGSize(width: 600, height: 800))
        let before = canvas.drawing.dataRepresentation()
        let stroke = InkStroke(ink: InkInk(.pen, color: .red), path: InkStrokePath(controlPoints: [point(10, time: 0)], creationDate: Date()))
        canvas.inkContentView.show(stroke)
        canvas.cancelActiveStroke()
        XCTAssertEqual(before, canvas.drawing.dataRepresentation())
        XCTAssertFalse(canvas.undoManager?.canUndo ?? true)
        XCTAssertNil(canvas.inkContentView.preview.path)
    }
}
