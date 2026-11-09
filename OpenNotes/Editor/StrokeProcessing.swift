import UIKit

enum StrokeProcessing {
    static func stabilizationInterval(_ level: Double) -> Double? {
        guard level.isFinite, level >= 0.01 else { return nil }
        return min(level, 1) * 0.04 + 0.02
    }

    static func snappedLine(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count == 2 else { return points }
        let start = points[0], end = points[1]
        let dx = end.x - start.x, dy = end.y - start.y
        let angle = atan2(dy, dx), target = (angle / (.pi / 4)).rounded() * (.pi / 4)
        guard abs(angle - target) <= .pi / 36 else { return points }
        let length = hypot(dx, dy)
        return [start, CGPoint(x: start.x + cos(target) * length, y: start.y + sin(target) * length)]
    }

    // Causal filtering keeps the prefix identical in live and saved geometry.
    static func process(_ stroke: InkStroke, tool: DrawingToolKind, width: Double, settings: EditorToolSettings, shapeHeld: Bool) -> InkStroke? {
        guard width.isFinite, width > 0, tool.isWritingTool else { return nil }
        let original = stroke.rawSamples.isEmpty ? Array(stroke.path) : stroke.rawSamples
        guard !original.isEmpty, original.allSatisfy({ $0.location.x.isFinite && $0.location.y.isFinite && $0.timeOffset.isFinite }) else { return nil }
        guard var live = Live(tool: tool, width: width, settings: settings) else { return nil }
        let duration = max(0.001, original.last?.timeOffset ?? 0)
        var shape = shapeHeld && settings.rulerEnabled != true && settings.shapeRecognitionEnabled && (live.pen || tool == .marker)
            ? ShapeRecognition.recognize(original.map(\.location), tolerance: AppPreferences.shapeTolerance, axisLock: AppPreferences.shapeAxisLock) : nil
        if settings.shapeAngleSnap == true, let points = shape, points.count == 2 {
            shape = snappedLine(points.map { $0.applying(stroke.transform) }).map { $0.applying(stroke.transform.inverted()) }
        }
        if let shape {
            for (index, location) in shape.enumerated() {
                let progress = Double(index) / Double(max(1, shape.count - 1))
                let sourceIndex = min(original.count - 1, Int((progress * Double(original.count - 1)).rounded()))
                var point = live.step(original[sourceIndex], at: location)
                point.timeOffset = duration * progress
                live.controls.append(point)
            }
        } else {
            for point in original { live.append(point) }
        }
        let controls = live.controls
        let style = live.style
        var result = stroke
        result.path = InkStrokePath(controlPoints: controls, creationDate: stroke.path.creationDate)
        result.rawSamples = original
        result.style = style
        return result
    }

    // Causal per-sample processing shared by the final stroke and the live preview, so both stay identical.
    // Copy the value to fork the filter state (e.g. for transient predictions).
    struct Live {
        fileprivate let tool: DrawingToolKind, settings: EditorToolSettings
        fileprivate let width: Double, response: Double, smoothing: Double, kind: EditorToolSettings.PenStyle
        let pen: Bool
        let style: InkStyle
        var controls: [InkStrokePoint] = []
        private var velocity = CGPoint.zero, filtered = CGPoint.zero, pressure = CGFloat(0.5)
        private var previous: InkStrokePoint?
        init?(tool: DrawingToolKind, width: Double, settings: EditorToolSettings) {
            guard width.isFinite, width > 0, tool.isWritingTool else { return nil }
            self.tool = tool; self.settings = settings; self.width = width
            pen = tool == .pen || tool == .fountainPen
            let level = settings.stabilization(for: tool)
            smoothing = level.isFinite ? min(1, max(0, level / 100)) : 0
            response = min(1, max(0, settings.pressureSensitivity ?? 0.5))
            kind = tool == .fountainPen ? .fountain : settings.penStyle
            style = InkStyle(kind: kind, width: width, pattern: pen ? settings.inkPattern ?? .solid : .solid,
                             sharpness: pen && kind != .ballpoint ? min(1, max(0, settings.tipSharpness ?? 0)) : 0,
                             stabilization: smoothing, pressureResponse: response)
        }
        mutating func append(_ original: InkStrokePoint) {
            var location = original.location
            if let before = previous {
                let dt = max(0.001, original.timeOffset - before.timeOffset)
                let derivativeAlpha = CGFloat(1 / (1 + 1 / (2 * Double.pi * dt)))
                velocity.x += derivativeAlpha * ((original.location.x - before.location.x) / dt - velocity.x)
                velocity.y += derivativeAlpha * ((original.location.y - before.location.y) / dt - velocity.y)
                // Starting calibration in page points; real Pencil latency needs hardware measurement.
                // At 0 % a light, fast filter still removes digitizer jitter (a few ms of lag) so lines don't look jagged.
                let speed = hypot(velocity.x, velocity.y)
                let cutoff = smoothing > 0 ? 6 - 5.5 * smoothing + (0.01 - 0.008 * smoothing) * speed : 20 + 0.02 * speed
                let alpha = CGFloat(1 / (1 + 1 / (2 * Double.pi * cutoff * dt)))
                location = CGPoint(x: filtered.x + alpha * (original.location.x - filtered.x),
                                   y: filtered.y + alpha * (original.location.y - filtered.y))
            }
            filtered = location; previous = original
            controls.append(step(original, at: location))
        }
        fileprivate mutating func step(_ original: InkStrokePoint, at location: CGPoint) -> InkStrokePoint {
            var point = original
            let rawPressure = point.force.isFinite ? min(1, max(0, point.force)) : 0.5
            pressure = controls.isEmpty ? rawPressure : pressure + 0.65 * (rawPressure - pressure)
            let p = settings.pressureEnabled == false ? CGFloat(0.5) : pressure
            let q = p * p * (3 - 2 * p)
            let power = 1.4 - 0.7 * response
            var diameter = width
            if pen, kind == .fountain { diameter *= 0.60 + 0.75 * pow(Double(q), power) }
            if pen, kind == .brush { diameter *= 0.20 + 1.75 * pow(Double(q), power) }
            if tool == .pencil, settings.pressureEnabled != false { diameter *= 0.5 + Double(p) }
            point.location = location
            point.size = CGSize(width: diameter, height: diameter)
            if settings.tiltEnabled == false { point.altitude = .pi / 2 }
            return point
        }
    }
}
