import Foundation
import CoreGraphics

// Conservative, explicit recognition: ambiguous strokes remain unchanged.
enum ShapeRecognition {
    struct Adjustment {
        private let original: [CGPoint]
        private let initialPointer: CGPoint

        init(points: [CGPoint], pointer: CGPoint) {
            original = points
            initialPointer = pointer
        }

        func points(at pointer: CGPoint) -> [CGPoint] {
            guard original.count >= 2,
                  (original + [initialPointer, pointer]).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return original }
            if original.count == 2 {
                let end = CGPoint(x: original[1].x + pointer.x - initialPointer.x,
                                  y: original[1].y + pointer.y - initialPointer.y)
                return end.x.isFinite && end.y.isFinite ? [original[0], end] : original
            }
            let xs = original.map(\.x), ys = original.map(\.y)
            let center = CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
            let initial = CGPoint(x: initialPointer.x - center.x, y: initialPointer.y - center.y)
            let current = CGPoint(x: pointer.x - center.x, y: pointer.y - center.y)
            let length = hypot(initial.x, initial.y)
            guard length > 1, hypot(current.x, current.y) > 1 else { return original }
            let scale = hypot(current.x, current.y) / length
            let angle = atan2(current.y, current.x) - atan2(initial.y, initial.x)
            let result = original.map { point in
                let x = point.x - center.x, y = point.y - center.y
                return CGPoint(x: center.x + scale * (x * cos(angle) - y * sin(angle)),
                               y: center.y + scale * (x * sin(angle) + y * cos(angle)))
            }
            return result.allSatisfy { $0.x.isFinite && $0.y.isFinite } ? result : original
        }
    }

    static func recognize(_ points: [CGPoint]) -> [CGPoint]? {
        guard points.count >= 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), let first = points.first, let last = points.last else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal > 20 else { return nil }
        let distance = hypot(last.x - first.x, last.y - first.y)
        if distance > diagonal * 0.85 {
            let deviation = points.map { abs((last.y - first.y) * $0.x - (last.x - first.x) * $0.y + last.x * first.y - last.y * first.x) / distance }.max()!
            if deviation < max(3, diagonal * 0.06) { return [first, last] }
            return fittedCurve(points, diagonal: diagonal)
        }
        guard distance < diagonal * 0.15, bounds.width > 20, bounds.height > 20, points.count > 8 else { return nil }
        let ellipseError = points.map { abs(hypot(($0.x - bounds.midX) / (bounds.width / 2), ($0.y - bounds.midY) / (bounds.height / 2)) - 1) }.reduce(0, +) / Double(points.count)
        if ellipseError < 0.1 {
            return (0...64).map { i in let angle = Double(i) / 64 * 2 * Double.pi; return CGPoint(x: bounds.midX + cos(angle) * bounds.width / 2, y: bounds.midY + sin(angle) * bounds.height / 2) }
        }
        // Fit a rectangle independently of its orientation, including hand-drawn corners.
        var rectangle: [CGPoint]?
        var bestError = diagonal * 0.025
        for step in 0..<30 {
            let angle = CGFloat(step) * .pi / 60
            let rotation = CGAffineTransform(rotationAngle: -angle)
            let rotated = points.map { $0.applying(rotation) }
            let xs = rotated.map(\.x), ys = rotated.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            guard box.width > 20, box.height > 20 else { continue }
            let corners = [box.origin, CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            let edgeError = rotated.map { min(abs($0.x - box.minX), abs($0.x - box.maxX), abs($0.y - box.minY), abs($0.y - box.maxY)) }.reduce(0, +) / Double(points.count)
            let coversCorners = corners.allSatisfy { corner in rotated.contains { hypot($0.x - corner.x, $0.y - corner.y) < diagonal * 0.12 } }
            if edgeError < bestError && coversCorners {
                bestError = edgeError
                rectangle = (corners + [corners[0]]).map { $0.applying(rotation.inverted()) }
            }
        }
        if let rectangle { return rectangle }
        let simplified = simplify(points, tolerance: diagonal * 0.035)
        guard (4...7).contains(simplified.count), let start = simplified.first else { return nil }
        let polygon = Array(simplified.dropLast()) + [start]
        let area = abs(zip(polygon, polygon.dropFirst()).reduce(CGFloat.zero) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
        return area > bounds.width * bounds.height * 0.25 ? polygon : nil
    }

    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        let length = hypot(last.x - first.x, last.y - first.y)
        let distances = points.map { point in
            length > 0.001 ? abs((last.y - first.y) * (point.x - first.x) - (last.x - first.x) * (point.y - first.y)) / length : hypot(point.x - first.x, point.y - first.y)
        }
        guard let index = distances.indices.max(by: { distances[$0] < distances[$1] }), distances[index] > tolerance,
              index > 0, index < points.count - 1 else { return [first, last] }
        return Array(simplify(Array(points[...index]), tolerance: tolerance).dropLast()) + simplify(Array(points[index...]), tolerance: tolerance)
    }

    private static func fittedCurve(_ points: [CGPoint], diagonal: CGFloat) -> [CGPoint]? {
        guard points.count >= 9, let first = points.first, let last = points.last else { return nil }
        var distances: [CGFloat] = [0]
        for pair in zip(points, points.dropFirst()) { distances.append(distances.last! + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)) }
        guard let length = distances.last, length > diagonal * 1.02, length < diagonal * 1.8 else { return nil }
        var numerator = CGPoint.zero, denominator: CGFloat = 0
        for (point, distance) in zip(points, distances) {
            let t = distance / length, a = (1 - t) * (1 - t), b = 2 * t * (1 - t), c = t * t
            numerator.x += b * (point.x - a * first.x - c * last.x)
            numerator.y += b * (point.y - a * first.y - c * last.y)
            denominator += b * b
        }
        guard denominator > 0 else { return nil }
        let control = CGPoint(x: numerator.x / denominator, y: numerator.y / denominator)
        func position(_ t: CGFloat) -> CGPoint {
            CGPoint(x: (1 - t) * (1 - t) * first.x + 2 * t * (1 - t) * control.x + t * t * last.x,
                    y: (1 - t) * (1 - t) * first.y + 2 * t * (1 - t) * control.y + t * t * last.y)
        }
        let error = zip(points, distances).reduce(CGFloat.zero) { sum, pair in
            let ideal = position(pair.1 / length)
            return sum + hypot(pair.0.x - ideal.x, pair.0.y - ideal.y)
        } / CGFloat(points.count)
        guard error < diagonal * 0.025 else { return nil }
        return (0...32).map { position(CGFloat($0) / 32) }
    }
}
