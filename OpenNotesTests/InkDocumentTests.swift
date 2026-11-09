import XCTest
import UIKit
@testable import OpenNotes

final class InkDocumentTests: XCTestCase {
    private func stroke(count: Int = 2, pattern: InkPattern = .solid) -> InkStroke {
        let points = (0..<count).map { index in
            InkStrokePoint(location: CGPoint(x: 10 + Double(index) * 100 / Double(max(1, count - 1)), y: 30),
                           timeOffset: Double(index) * 0.01, size: CGSize(width: 6, height: 6), opacity: 1,
                           force: 0.5, azimuth: 0.2, altitude: 1)
        }
        return InkStroke(ink: InkInk(.pen, color: .red),
                         path: InkStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 1)),
                         style: InkStyle(width: 6, pattern: pattern))
    }
    func testRoundTripRetainsIdentityRawSamplesFrozenStyleAndTransform() throws {
        var original = stroke(pattern: .dashed)
        original.transform = CGAffineTransform(rotationAngle: 0.3).translatedBy(x: 12, y: -6)
        original.style?.sharpness = 0.75
        original.rawSamples[1].force = 0.9
        let source = InkDrawing(strokes: [original])
        let saved = try InkDrawing(data: source.dataRepresentation())
        let decoded = try XCTUnwrap(saved.strokes.first)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.rawSamples, original.rawSamples)
        XCTAssertEqual(Array(decoded.path), Array(original.path))
        XCTAssertEqual(decoded.style, original.style)
        XCTAssertEqual(decoded.transform, original.transform)
        XCTAssertEqual(saved.dataRepresentation(), source.dataRepresentation())
    }
    func testRawSamplesAreOmittedWhenIdenticalAndLegacyFilesStillDecode() throws {
        let plain = InkDrawing(strokes: [stroke(count: 50)])
        var edited = stroke(count: 50); edited.rawSamples[3].force = 0.9
        let plainJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: plain.encodedData()) as? [String: Any])
        let editedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: InkDrawing(strokes: [edited]).encodedData()) as? [String: Any])
        XCTAssertNil((plainJSON["strokes"] as? [[String: Any]])?[0]["rawSamples"])
        XCTAssertNotNil((editedJSON["strokes"] as? [[String: Any]])?[0]["rawSamples"])
        // Older builds always wrote rawSamples: re-insert it and expect an identical drawing back.
        var legacy = plainJSON
        var strokes = try XCTUnwrap(legacy["strokes"] as? [[String: Any]])
        strokes[0]["rawSamples"] = (strokes[0]["path"] as? [String: Any])?["controlPoints"]
        legacy["strokes"] = strokes
        let decoded = try InkDrawing(data: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.strokes[0].rawSamples, plain.strokes[0].rawSamples)
        XCTAssertEqual(try decoded.encodedData(), try plain.encodedData())
    }
    func testRejectsLegacyUnknownSchemaInvalidColorAndNonfiniteCoordinate() throws {
        XCTAssertThrowsError(try InkDrawing(data: Data([0, 1, 2, 3])))
        let data = InkDrawing(strokes: [stroke()]).dataRepresentation()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["inkSchemaVersion"] = 200
        XCTAssertThrowsError(try InkDrawing(data: JSONSerialization.data(withJSONObject: root)))
        var text = try XCTUnwrap(String(data: data, encoding: .utf8))
        text = text.replacingOccurrences(of: "\"rgbaSRGB\":[1,0,0,1]", with: "\"rgbaSRGB\":[2,0,0,1]")
        XCTAssertThrowsError(try InkDrawing(data: Data(text.utf8)))
        text = try XCTUnwrap(String(data: data, encoding: .utf8))
        text = text.replacingOccurrences(of: "\"timeOffset\":0", with: "\"timeOffset\":-1")
        XCTAssertThrowsError(try InkDrawing(data: Data(text.utf8)))
    }
    func testInvalidInMemoryGeometryFailsCheckedSerialization() {
        var invalid = stroke()
        invalid.rawSamples[0].location.x = .nan
        XCTAssertThrowsError(try InkDrawing(strokes: [invalid]).encodedData())
    }
    func testPatternsUseArcDistanceIndependentlyOfSampleCount() {
        for pattern in [InkPattern.dashed, .dotted] {
            let sparse = stroke(pattern: pattern).paintedPaths()
            let dense = stroke(count: 101, pattern: pattern).paintedPaths()
            XCTAssertEqual(sparse.count, dense.count)
            for (a, b) in zip(sparse, dense) {
                XCTAssertEqual(a.first!.location.x, b.first!.location.x, accuracy: 0.0001)
                XCTAssertEqual(a.last!.location.x, b.last!.location.x, accuracy: 0.0001)
            }
        }
        let dots = stroke(pattern: .dotted).paintedPaths()
        XCTAssertEqual(dots[1][0].location.x - dots[0][0].location.x, 13.2, accuracy: 0.0001)
    }
    func testPointAndZeroLengthRemainVisibleAtFullSharpness() {
        var point = stroke(count: 1)
        point.style?.sharpness = 1
        XCTAssertFalse(point.paintedPath.isEmpty)
        XCTAssertTrue(point.paintedPath.contains(CGPoint(x: 10, y: 30)))
        var repeated = point
        repeated.path = InkStrokePath(controlPoints: Array(repeating: point.path[0], count: 3), creationDate: Date())
        XCTAssertTrue(repeated.paintedPath.contains(CGPoint(x: 10, y: 30)))
        XCTAssertTrue(stroke().paintedPath.contains(CGPoint(x: 60, y: 30)))
    }
    func testSharpnessTapersSparseLineCapsWithoutNarrowingTheShaft() throws {
        var line = stroke()
        line.style?.sharpness = 1
        let points = try XCTUnwrap(line.paintedPaths().first)
        XCTAssertLessThan(try XCTUnwrap(points.first).size.width, 1)
        XCTAssertLessThan(try XCTUnwrap(points.last).size.width, 1)
        XCTAssertEqual(points.map(\.size.width).max(), 6)
        XCTAssertGreaterThan(points.count, 2)
        XCTAssertTrue(line.paintedPath.contains(CGPoint(x: 60, y: 32)), "A sparse held line keeps its full-width shaft")
    }
    func testRenderingIsStableAfterReload() throws {
        var source = stroke(count: 20, pattern: .dashed)
        source.style?.sharpness = 0.6
        let drawing = InkDrawing(strokes: [source])
        let reopened = try InkDrawing(data: drawing.dataRepresentation())
        let rect = CGRect(x: 0, y: 0, width: 128, height: 64)
        XCTAssertEqual(drawing.image(from: rect, scale: 2).pngData(), reopened.image(from: rect, scale: 2).pngData())
    }
}
