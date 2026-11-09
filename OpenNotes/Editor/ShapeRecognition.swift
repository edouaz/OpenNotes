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

    /// `tolerance` > 1 accepts rougher drawings (1 = the original strict thresholds).
    /// `axisLock` (degrees) pulls lines, rectangles and polygon edges that are nearly horizontal or vertical onto the axis.
    static func recognize(_ points: [CGPoint], tolerance: CGFloat = 1, axisLock: CGFloat = 0) -> [CGPoint]? {
        let tolerance = min(max(tolerance.isFinite ? tolerance : 1, 0.5), 2)
        let lock = min(max(axisLock.isFinite ? axisLock : 0, 0), 20) * .pi / 180
        guard points.count >= 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), let first = points.first, let last = points.last else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal > 20 else { return nil }
        let distance = hypot(last.x - first.x, last.y - first.y)
        if distance > diagonal * 0.85 {
            let deviation = points.map { abs((last.y - first.y) * $0.x - (last.x - first.x) * $0.y + last.x * first.y - last.y * first.x) / distance }.max()!
            if deviation < max(3, diagonal * 0.06 * tolerance) { return lockedLine(first, last, lock: lock) }
            return fittedCurve(points, diagonal: diagonal)
        }
        guard distance < diagonal * 0.15 * tolerance, bounds.width > 20, bounds.height > 20, points.count > 8 else { return nil }
        let ellipseError = points.map { abs(hypot(($0.x - bounds.midX) / (bounds.width / 2), ($0.y - bounds.midY) / (bounds.height / 2)) - 1) }.reduce(0, +) / Double(points.count)
        if ellipseError < 0.1 * tolerance {
            // A nearly round ellipse becomes a perfect circle; only clearly elongated ones stay ovals.
            let ratio = min(bounds.width, bounds.height) / max(bounds.width, bounds.height)
            let round = tolerance > 1 && ratio >= 1 - 0.12 * tolerance
            let radius = (bounds.width + bounds.height) / 4
            let rx = round ? radius : bounds.width / 2, ry = round ? radius : bounds.height / 2
            return (0...64).map { i in let angle = Double(i) / 64 * 2 * Double.pi; return CGPoint(x: bounds.midX + cos(angle) * rx, y: bounds.midY + sin(angle) * ry) }
        }
        // Fit a rectangle independently of its orientation, including hand-drawn corners.
        var rectangle: [CGPoint]?
        var bestError = diagonal * 0.025 * tolerance
        var bestAngle: CGFloat = 0
        func box(at angle: CGFloat) -> (corners: [CGPoint], rotation: CGAffineTransform, error: CGFloat, covers: Bool)? {
            let rotation = CGAffineTransform(rotationAngle: -angle)
            let rotated = points.map { $0.applying(rotation) }
            let xs = rotated.map(\.x), ys = rotated.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            guard box.width > 20, box.height > 20 else { return nil }
            let corners = [box.origin, CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            let edgeError = rotated.map { min(abs($0.x - box.minX), abs($0.x - box.maxX), abs($0.y - box.minY), abs($0.y - box.maxY)) }.reduce(0, +) / CGFloat(points.count)
            let covers = corners.allSatisfy { corner in rotated.contains { hypot($0.x - corner.x, $0.y - corner.y) < diagonal * 0.12 * tolerance } }
            return (corners, rotation, edgeError, covers)
        }
        for step in 0..<30 {
            let angle = CGFloat(step) * .pi / 60
            guard let fit = box(at: angle), fit.error < bestError, fit.covers else { continue }
            bestError = fit.error; bestAngle = angle
            rectangle = (fit.corners + [fit.corners[0]]).map { $0.applying(fit.rotation.inverted()) }
        }
        // A rectangle drawn a few degrees off the axes snaps square to the page.
        if rectangle != nil, lock > 0 {
            let off = bestAngle.truncatingRemainder(dividingBy: .pi / 2)
            if min(off, .pi / 2 - off) <= lock, let fit = box(at: 0), fit.error < diagonal * 0.04 * tolerance {
                rectangle = fit.corners + [fit.corners[0]]
            }
        }
        if let rectangle { return rectangle }
        // Polygons (triangles first): retry with a coarser simplification so a wobbly side does not add a corner.
        for factor in tolerance > 1 ? [0.035, 0.035 * tolerance, 0.05 * tolerance] : [0.035] {
            let simplified = simplify(points, tolerance: diagonal * factor)
            guard (4...7).contains(simplified.count) else { continue }
            var corners = Array(simplified.dropLast())
            if lock > 0 { corners = lockedEdges(corners, lock: lock) }
            let polygon = corners + [corners[0]]
            let area = abs(zip(polygon, polygon.dropFirst()).reduce(CGFloat.zero) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
            if area > bounds.width * bounds.height * (tolerance > 1 ? 0.2 : 0.25) { return polygon }
        }
        return nil
    }

    /// A line within `lock` radians of horizontal or vertical is made exactly so, keeping its start and length.
    static func lockedLine(_ start: CGPoint, _ end: CGPoint, lock: CGFloat) -> [CGPoint] {
        guard lock > 0 else { return [start, end] }
        let dx = end.x - start.x, dy = end.y - start.y, length = hypot(dx, dy)
        let angle = atan2(dy, dx), target = (angle / (.pi / 2)).rounded() * (.pi / 2)
        guard abs(angle - target) <= lock else { return [start, end] }
        return [start, CGPoint(x: start.x + cos(target) * length, y: start.y + sin(target) * length)]
    }

    /// Edges close to horizontal or vertical are straightened by moving both of their corners to the shared coordinate.
    private static func lockedEdges(_ corners: [CGPoint], lock: CGFloat) -> [CGPoint] {
        var result = corners
        for index in result.indices {
            let a = result[index], b = result[(index + 1) % result.count]
            let angle = abs(atan2(b.y - a.y, b.x - a.x))
            if min(angle, .pi - angle) <= lock {
                let y = (a.y + b.y) / 2; result[index].y = y; result[(index + 1) % result.count].y = y
            } else if abs(angle - .pi / 2) <= lock {
                let x = (a.x + b.x) / 2; result[index].x = x; result[(index + 1) % result.count].x = x
            }
        }
        return result
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
