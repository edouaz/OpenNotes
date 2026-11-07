import UIKit

enum EraserEditing {
    static func erase(_ drawing: InkDrawing, along points: [CGPoint], width: Double, mode: EditorToolSettings.EraserMode, erasePen: Bool = true, eraseHighlighter: Bool = true) -> InkDrawing {
        guard !points.isEmpty, width.isFinite, width > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return drawing }
        let effectiveWidth = width + (mode == .standard ? 4 : 0)
        let radius = CGFloat(effectiveWidth / 2)
        let sweep = CGMutablePath()
        sweep.move(to: points[0])
        for point in points.dropFirst() { sweep.addLine(to: point) }
        let area: CGPath = points.allSatisfy { $0 == points[0] }
            ? CGPath(ellipseIn: CGRect(x: points[0].x - radius, y: points[0].y - radius, width: effectiveWidth, height: effectiveWidth), transform: nil)
            : sweep.copy(strokingWithWidth: effectiveWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
        let strokes = drawing.strokes.flatMap { stroke -> [InkStroke] in
            guard stroke.isLocked != true else { return [stroke] }
            guard stroke.ink.inkType == .marker ? eraseHighlighter : erasePen else { return [stroke] }
            guard stroke.renderBounds.intersects(area.boundingBoxOfPath) else { return [stroke] }
            let transform = stroke.transform
            let originalPaint = stroke.paintedPath
            // Test in stroke space: transforming the small eraser area is far cheaper than copying the whole stroke path.
            var inverse = transform.inverted()
            guard let localArea = area.copy(using: &inverse) else { return [stroke] }
            // Plain strokes are a union of dots and quads: a distance test is exact and linear, whereas CGPath
            // booleans grow superlinearly with sample count. Edited strokes carry an outline and keep the path test.
            let hit = stroke.vectorOutline == nil ? touches(stroke, along: points, reach: radius) : originalPaint.intersects(localArea)
            guard hit else { return [stroke] }
            if mode == .precision {
                var remaining = stroke.vectorOutline == nil ? paint(of: stroke, subtracting: localArea) : originalPaint.subtracting(localArea)
                // Untouched primitives stay raw (bigger than a simplified outline): past this size take the compact full boolean.
                if stroke.vectorOutline == nil, InkVectorPath(remaining).elements.count > 40_000 { remaining = originalPaint.subtracting(localArea) }
                guard !remaining.isEmpty else { return [] }
                var clipped = stroke
                clipped.vectorOutline = InkVectorPath(remaining)
                return [clipped]
            }
            if mode == .stroke || (mode == .intelligent && max(stroke.renderBounds.width, stroke.renderBounds.height) <= width) { return [] }
            let scale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
            func erased(_ sample: InkStrokePoint) -> Bool {
                distance(sample.location.applying(transform), to: points) <= radius + max(sample.size.width, sample.size.height) * scale / 2
            }
            var fragments: [InkStroke] = []
            for piece in stroke.paintedPaths() {
                guard !piece.isEmpty else { continue }
                let path = InkStrokePath(controlPoints: piece, creationDate: stroke.path.creationDate)
                let samples = Array(path.interpolatedPoints(by: .distance(0.5)))
                guard let first = samples.first else { continue }
                var kept: [InkStrokePoint] = erased(first) ? [] : [first]
                func finish() {
                    guard !kept.isEmpty else { return }
                    var fragment = stroke
                    fragment.id = UUID()
                    fragment.path = InkStrokePath(controlPoints: kept, creationDate: stroke.path.creationDate)
                    fragment.rawSamples = kept
                    // Painted pieces already contain the original pattern and taper geometry.
                    if var style = fragment.style { style.pattern = .solid; style.sharpness = 0; fragment.style = style }
                    // Kept samples are linear subdivisions of the original ones, so a plain stroke's fragment repaints the same
                    // dots and quads: no CGPath intersection (quadratic in samples) and it stays cheap to hit.
                    // A precision-edited stroke has holes its samples don't know about, so it is still clipped to its outline.
                    fragment.vectorOutline = nil
                    if stroke.vectorOutline != nil {
                        let clipped = fragment.paintedPath.intersection(originalPaint)
                        guard !clipped.isEmpty else { kept = []; return }
                        fragment.vectorOutline = InkVectorPath(clipped)
                    }
                    fragments.append(fragment)
                    kept = []
                }
                for pair in zip(samples, samples.dropFirst()) {
                    let beforeErased = erased(pair.0), afterErased = erased(pair.1)
                    if beforeErased != afterErased {
                        var low: CGFloat = 0, high: CGFloat = 1
                        for _ in 0..<12 {
                            let middle = (low + high) / 2
                            if erased(interpolate(pair.0, pair.1, middle)) == beforeErased { low = middle } else { high = middle }
                        }
                        let boundary = interpolate(pair.0, pair.1, beforeErased ? high : low)
                        if beforeErased { kept = [boundary, pair.1] }
                        else { kept.append(boundary); finish() }
                    } else if !afterErased { kept.append(pair.1) }
                }
                finish()
            }
            return fragments
        }
        return InkDrawing(strokes: strokes)
    }

    // union(all) - area == union(far) + (union(near) - area) when far primitives never reach the area, so the
    // costly boolean only sees the dots and quads around the eraser. Output windings stay compatible (checked in tests).
    static func paint(of stroke: InkStroke, subtracting area: CGPath) -> CGPath {
        let box = area.boundingBoxOfPath
        let near = CGMutablePath(), far = CGMutablePath()
        for piece in stroke.paintedPaths() where !piece.isEmpty {
            for i in 0..<max(1, piece.count - 1) {
                let pair = Array(piece[i...min(i + 1, piece.count - 1)])
                let r = pair.map { max(0.025, max($0.size.width, $0.size.height) / 2) }.max() ?? 0
                let rect = pair.reduce(CGRect.null) { $0.union(CGRect(origin: $1.location, size: .zero)) }.insetBy(dx: -r, dy: -r)
                InkStroke.addOutline(of: pair, from: 0, to: rect.intersects(box) ? near : far)
            }
        }
        let result = CGMutablePath()
        result.addPath(far)
        if !near.isEmpty { result.addPath(near.subtracting(area)) }
        return result
    }

    // True when the swept eraser (capsule of `reach` around `points`) overlaps the stroke's dots and quads.
    static func touches(_ stroke: InkStroke, along points: [CGPoint], reach: CGFloat) -> Bool {
        touches(stroke, segments: points.count == 1 ? [(points[0], points[0])] : Array(zip(points, points.dropFirst())), reach: reach)
    }

    // Shared by the eraser (swept capsule) and the lasso (polygon edges plus an inside test, reach 0).
    static func touches(_ stroke: InkStroke, segments sweep: [(CGPoint, CGPoint)], reach: CGFloat, inside: ((CGPoint) -> Bool)? = nil) -> Bool {
        let t = stroke.transform
        let scale = max(hypot(t.a, t.b), hypot(t.c, t.d))
        func closest(_ x: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (d: CGFloat, t: CGFloat) {
            let dx = b.x - a.x, dy = b.y - a.y, l = dx * dx + dy * dy
            let u = l > 0 ? min(1, max(0, ((x.x - a.x) * dx + (x.y - a.y) * dy) / l)) : 0
            return (hypot(x.x - a.x - u * dx, x.y - a.y - u * dy), u)
        }
        func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        for piece in stroke.paintedPaths() {
            let world = piece.map { ($0.location.applying(t), max(0.025, max($0.size.width, $0.size.height) / 2) * scale) }
            if let inside, world.contains(where: { inside($0.0) }) { return true }
            for i in 0..<max(1, world.count - 1) {
                let (a, ra) = world[i], (b, rb) = world[min(i + 1, world.count - 1)]
                let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -(max(ra, rb) + reach), dy: -(max(ra, rb) + reach))
                for (p, q) in sweep where box.contains(p) || box.contains(q) || box.intersects(CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))) {
                    if side(a, b, p) * side(a, b, q) < 0 && side(p, q, a) * side(p, q, b) < 0 { return true }
                    if closest(a, p, q).d <= reach + ra || closest(b, p, q).d <= reach + rb { return true }
                    for e in [p, q] { let c = closest(e, a, b); if c.d <= reach + ra + (rb - ra) * c.t { return true } }
                }
            }
        }
        return false
    }

    // Cheap geometry comparison; avoids JSON-encoding whole pages on the main thread.
    static func changed(_ a: InkDrawing, _ b: InkDrawing) -> Bool {
        a.strokes.count != b.strokes.count || zip(a.strokes, b.strokes).contains {
            $0.id != $1.id || $0.vectorOutline != $1.vectorOutline || $0.path.controlPoints != $1.path.controlPoints
        }
    }

    static func interpolate(_ a: InkStrokePoint, _ b: InkStrokePoint, _ t: CGFloat) -> InkStrokePoint {
        InkStrokePoint(location: CGPoint(x: a.location.x + (b.location.x - a.location.x) * t, y: a.location.y + (b.location.y - a.location.y) * t),
                       timeOffset: a.timeOffset + (b.timeOffset - a.timeOffset) * Double(t),
                       size: CGSize(width: a.size.width + (b.size.width - a.size.width) * t, height: a.size.height + (b.size.height - a.size.height) * t),
                       opacity: a.opacity + (b.opacity - a.opacity) * t, force: a.force + (b.force - a.force) * t,
                       azimuth: a.azimuth + (b.azimuth - a.azimuth) * t, altitude: a.altitude + (b.altitude - a.altitude) * t)
    }

    static func distance(_ point: CGPoint, to path: [CGPoint]) -> CGFloat {
        guard let first = path.first else { return .infinity }
        var nearest = hypot(point.x - first.x, point.y - first.y)
        for pair in zip(path, path.dropFirst()) {
            let dx = pair.1.x - pair.0.x, dy = pair.1.y - pair.0.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(1, max(0, ((point.x - pair.0.x) * dx + (point.y - pair.0.y) * dy) / lengthSquared)) : 0
            nearest = min(nearest, hypot(point.x - pair.0.x - t * dx, point.y - pair.0.y - t * dy))
        }
        return nearest
    }
}
