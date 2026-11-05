import CoreGraphics
import XCTest
@testable import OpenNotes

final class ShapeRecognitionTests: XCTestCase {
    func testConservativeRecognition() {
        XCTAssertEqual(ShapeRecognition.recognize([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 1), CGPoint(x: 200, y: 0)])?.count, 2)
        XCTAssertNil(ShapeRecognition.recognize([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 0)]))
        XCTAssertNil(ShapeRecognition.recognize([.zero]))
        let ellipse = (0...32).map { i in let a = Double(i) / 32 * 2 * Double.pi; return CGPoint(x: 100 + cos(a) * 80, y: 100 + sin(a) * 50) }
        XCTAssertEqual(ShapeRecognition.recognize(ellipse)?.count, 65)
    }
    func testWobblyLineAndRotatedRectangle() throws {
        let line = (0...20).map { CGPoint(x: $0 * 5, y: $0 % 2 == 0 ? 2 : -2) }
        XCTAssertEqual(ShapeRecognition.recognize(line)?.count, 2)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 0), CGPoint(x: 120, y: 80), CGPoint(x: 0, y: 80), .zero]
        let rectangle: [CGPoint] = (0..<4).flatMap { edge -> [CGPoint] in
            (0..<12).map { step in
                let t = CGFloat(step) / 12
                let start = corners[edge], end = corners[edge + 1]
                let wobble: CGFloat = step % 2 == 0 ? 1 : -1
                let x = start.x + (end.x - start.x) * t + wobble
                let y = start.y + (end.y - start.y) * t
                return CGPoint(x: x, y: y)
            }
        } + [.zero]
        for angle: CGFloat in [0, .pi / 6, .pi / 4, 1.1] {
            let result = try XCTUnwrap(ShapeRecognition.recognize(rectangle.map { $0.applying(CGAffineTransform(rotationAngle: angle)) }))
            XCTAssertEqual(result.count, 5)
            XCTAssertEqual(result.first, result.last)
        }
    }

    func testHeldLineRotatesWithoutJumpingOrMovingItsStart() {
        let points = [CGPoint(x: 20, y: 30), CGPoint(x: 120, y: 30)]
        let pointer = CGPoint(x: 121, y: 32)
        let adjustment = ShapeRecognition.Adjustment(points: points, pointer: pointer)
        XCTAssertEqual(adjustment.points(at: pointer), points)
        XCTAssertEqual(adjustment.points(at: CGPoint(x: 21, y: 132)), [points[0], CGPoint(x: 20, y: 130)])
    }

    func testClosedAdjustmentPreservesShapeAndHandlesDegeneratePointers() throws {
        let points = [CGPoint(x: -40, y: -20), CGPoint(x: 40, y: -20), CGPoint(x: 40, y: 20), CGPoint(x: -40, y: 20), CGPoint(x: -40, y: -20)]
        let adjustment = ShapeRecognition.Adjustment(points: points, pointer: CGPoint(x: 40, y: 0))
        XCTAssertEqual(adjustment.points(at: CGPoint(x: 40, y: 0)), points)
        let moved = adjustment.points(at: CGPoint(x: 0, y: 80))
        XCTAssertEqual(moved.first, moved.last)
        XCTAssertEqual(moved[0].x, 40, accuracy: 0.001)
        XCTAssertEqual(moved[0].y, -80, accuracy: 0.001)
        XCTAssertTrue(moved.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertEqual(adjustment.points(at: .zero), points)
        XCTAssertEqual(adjustment.points(at: CGPoint(x: CGFloat.nan, y: 0)), points)
        XCTAssertEqual(ShapeRecognition.Adjustment(points: points, pointer: .zero).points(at: CGPoint(x: 30, y: 30)), points)
        XCTAssertTrue(ShapeRecognition.Adjustment(points: [], pointer: .zero).points(at: .zero).isEmpty)
    }

}
