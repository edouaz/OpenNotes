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
            guard let localArea = area.copy(using: &inverse), originalPaint.intersects(localArea) else { return [stroke] }
            if mode == .precision {
                let remaining = originalPaint.subtracting(localArea)
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
                    fragment.vectorOutline = nil
                    let clipped = fragment.paintedPath.intersection(originalPaint)
                    guard !clipped.isEmpty else { kept = []; return }
                    fragment.vectorOutline = InkVectorPath(clipped)
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
